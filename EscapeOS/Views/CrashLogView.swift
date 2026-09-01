import SwiftUI

/// 崩溃分析：通过「配对文件 + LocalDevVPN」隧道读取本机崩溃 / 诊断日志
/// （对应 iOS「设置 → 隐私与安全性 → 分析与改进」），支持查看内容、
/// 批量选择（含全选）导出到本机与删除。
struct CrashLogView: View {
    @State private var entries: [CrashLogService.Entry] = []
    @State private var currentDir: String?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selection = Set<String>()
    @State private var isEditing = false
    @State private var previewEntry: CrashLogService.Entry?
    @State private var previewText = ""
    @State private var previewLoading = false
    @State private var toast: String?
    @State private var confirmDelete = false
    @State private var exporting = false
    /// 批量操作中（导出 / 删除）：显示进度，禁用重复操作。
    @State private var busy = false
    /// 进度文本（如「3 / 12」）。
    @State private var progressText: String?

    private let service = CrashLogService.shared

    private var selectedEntries: [CrashLogService.Entry] {
        entries.filter { selection.contains($0.id) }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在连接崩溃日志服务…")
                            .foregroundColor(.secondary)
                    }
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                    Button("重试") { reload() }
                } else if entries.isEmpty {
                    Text("没有日志")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
            } header: {
                Text(currentDir.map { "目录：\($0)" } ?? "目录：/")
            } footer: {
                if !loading && errorMessage == nil {
                    Text("对应「设置 → 隐私与安全性 → 分析与改进」。支持批量导出 / 删除。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle("崩溃分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                if isEditing {
                    Button("全选") { selectAll() }
                } else {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新")
                    .disabled(busy)
                    if currentDir != nil {
                        Button {
                            currentDir = nil
                            reload()
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .accessibilityLabel("返回根目录")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !entries.isEmpty && !busy {
                    Button(isEditing ? "完成" : "选择") {
                        withAnimation { isEditing.toggle() }
                        if !isEditing { selection.removeAll() }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                bottomBar
            }
        }
        .overlay {
            // v0.2.125：批量导出 / 删除进度遮罩（旧版无进度、且导出会闪退）。
            if busy {
                VStack(spacing: 12) {
                    ProgressView()
                    if let progressText {
                        Text(progressText)
                            .font(.subheadline.weight(.medium))
                    }
                    Text("正在处理…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8)
            }
        }
        .sheet(item: $previewEntry) { entry in
            NavigationView {
                Group {
                    if previewLoading {
                        ProgressView("正在拉取日志…")
                    } else if previewText.isEmpty {
                        Text("（空文件）")
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            Text(previewText)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { previewEntry = nil }
                    }
                }
            }
        }
        .confirmationDialog(
            "删除选中的 \(selectedEntries.count) 个日志？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
        .onAppear {
            if entries.isEmpty && errorMessage == nil { reload() }
        }
    }

    private var bottomBar: some View {
        HStack {
            Text("已选 \(selectedEntries.count) 项")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                exportSelected()
            } label: {
                Label("导出", systemImage: "square.and.arrow.down")
            }
            .disabled(selection.isEmpty || busy)
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selection.isEmpty || busy)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 行

    private func row(_ entry: CrashLogService.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text.fill")
                .foregroundColor(entry.isDirectory ? .blue : .secondary)
                .frame(width: 28)
            Text(entry.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            if !isEditing && !entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            open(entry)
        }
    }

    // MARK: - 数据

    private func reload() {
        loading = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let list = try service.list(subdirectory: currentDir)
                DispatchQueue.main.async {
                    entries = list
                    loading = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "\(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }

    private func open(_ entry: CrashLogService.Entry) {
        guard !busy else { return }
        // v0.2.127：AFC 视图能明确区分目录/文件 —— 目录直接进入，
        // 文件拉取预览（爱思同款，可进入 CrashReporter / DiagnosticLogs 子目录）。
        if entry.isDirectory {
            currentDir = entry.path
            reload()
            return
        }
        previewEntry = entry
        previewText = ""
        previewLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try service.pull(entry.path)
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16) ?? "（二进制内容，无法显示）"
                DispatchQueue.main.async {
                    previewText = text
                    previewLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    previewEntry = nil
                    previewLoading = false
                    toast = "无法打开：\(error.localizedDescription)"
                }
            }
        }
    }

    private func selectAll() {
        if selection.count == entries.count {
            selection.removeAll()
        } else {
            selection = Set(entries.map(\.id))
        }
    }

    private func exportSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty, !busy else { return }
        busy = true
        exporting = true
        progressText = "0 / \(targets.count)"
        isEditing = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let paths = try service.export(entries: targets) { done, total in
                    DispatchQueue.main.async {
                        progressText = "\(done) / \(total)"
                    }
                }
                DispatchQueue.main.async {
                    busy = false
                    exporting = false
                    selection.removeAll()
                    toast = "已导出 \(paths.count) 个日志到 App 的 CrashLogs 目录（文件 App 可见）"
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    exporting = false
                    toast = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty, !busy else { return }
        busy = true
        progressText = "0 / \(targets.count)"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let failed = try service.removeBatch(targets) { done, total in
                    DispatchQueue.main.async {
                        progressText = "\(done) / \(total)"
                    }
                }
                DispatchQueue.main.async {
                    busy = false
                    selection.removeAll()
                    toast = failed == 0
                        ? "已删除 \(targets.count) 个日志"
                        : "已删除 \(targets.count - failed) 个，失败 \(failed) 个"
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    toast = "删除失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
