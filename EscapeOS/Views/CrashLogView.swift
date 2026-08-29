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

    private let service = CrashLogService.shared

    /// 常见的日志文件后缀（用于区分文件与子目录）。
    private static let fileSuffixes = [".ips", ".log", ".txt", ".panic", ".crash", ".json", ".plist", ".synced"]

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
                Text(currentDir.map { "目录：\($0)" } ?? "目录：根（崩溃报告 / 诊断日志）")
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
            ToolbarItem(placement: .navigationBarLeading) {
                if isEditing {
                    Button("全选") { selectAll() }
                } else if currentDir != nil {
                    Button {
                        currentDir = nil
                        reload()
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .accessibilityLabel("返回根目录")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !entries.isEmpty {
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
            .disabled(selection.isEmpty || exporting)
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 行

    private func row(_ entry: CrashLogService.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isFile(entry.name) ? "doc.text.fill" : "folder.fill")
                .foregroundColor(isFile(entry.name) ? .secondary : .blue)
                .frame(width: 28)
            Text(entry.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            if !isEditing && isFile(entry.name) {
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

    private func isFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return Self.fileSuffixes.contains { lower.hasSuffix($0) }
            || !lower.contains(".")
    }

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
        // 先尝试按文件拉取内容预览；失败（可能是目录）则尝试进入子目录。
        // 这样不依赖文件名后缀猜测，目录 / 文件都能正确处理。
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
                // 拉取失败 → 当作子目录进入。
                DispatchQueue.main.async {
                    previewEntry = nil
                    previewLoading = false
                    currentDir = entry.path
                    reload()
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
        exporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let paths = try service.export(entries: targets)
                DispatchQueue.main.async {
                    exporting = false
                    toast = "已导出 \(paths.count) 个日志到 App 的 CrashLogs 目录（文件 App 可见）"
                }
            } catch {
                DispatchQueue.main.async {
                    exporting = false
                    toast = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteSelected() {
        let targets = selectedEntries
        DispatchQueue.global(qos: .userInitiated).async {
            var failed = 0
            for entry in targets {
                do { try service.remove(entry.path) }
                catch { failed += 1 }
            }
            DispatchQueue.main.async {
                selection.removeAll()
                toast = failed == 0
                    ? "已删除 \(targets.count) 个日志"
                    : "已删除 \(targets.count - failed) 个，失败 \(failed) 个"
                reload()
            }
        }
    }
}
