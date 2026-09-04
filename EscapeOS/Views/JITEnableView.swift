import SwiftUI
import UIKit

/// 启用 JIT（汉化移植自 StikDebug，对齐原版 Home 的列表组织）.
/// 布局与 StikDebug 一致：导航栏常驻搜索框 + 「最近使用」分组 +
/// 「Apps with get-task-allow」全部分组；行内显示 App 图标 + 名称 + Bundle ID.
struct JITEnableView: View {
    @State private var apps: [JITAppInfo] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var confirmTarget: JITAppInfo?
    @State private var progressText = ""
    @State private var isWorking = false
    @State private var successMessage = ""
    @State private var showSuccess = false
    @State private var searchText = ""
    @State private var recentBundleIDs: [String] = UserDefaults.standard.stringArray(forKey: "escape.jitRecents") ?? []

    private var hasPairing: Bool { TunnelContext.shared.hasPairingFile }

    private var filteredApps: [JITAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    private var recentApps: [JITAppInfo] {
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })
        return recentBundleIDs.compactMap { byID[$0] }
    }

    var body: some View {
        List {
            if isLoading && apps.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("正在枚举可启用 JIT 的应用…")
                        Spacer()
                    }
                }
            } else if apps.isEmpty && !isLoading {
                Section {
                    if !hasPairing {
                        Label("未检测到配对文件", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("启用 JIT 需要：① 配对文件（在「应用」页导入）；② LocalDevVPN 已连接；③ 应用签名带 get-task-allow.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未找到可启用 JIT 的应用.")
                            .foregroundStyle(.secondary)
                        Text("只有签名带 get-task-allow（开发签名 / 证书直装）的应用才能启用 JIT；App Store 应用不适用.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                if !searchText.isEmpty && filteredApps.isEmpty {
                    Section {
                        Text("没有匹配的应用.")
                            .foregroundStyle(.secondary)
                        Text("换个名称或 Bundle ID 试试.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !recentApps.isEmpty && searchText.isEmpty {
                        Section {
                            ForEach(recentApps) { app in
                                jitRow(app)
                            }
                        } header: {
                            Label("最近使用", systemImage: "clock")
                        }
                    }

                    Section {
                        ForEach(filteredApps) { app in
                            jitRow(app)
                        }
                    } header: {
                        Label("Apps with get-task-allow", systemImage: "bolt.badge.a.fill")
                    } footer: {
                        Text("点击应用后将以调试模式启动它,JIT 权限在应用运行期间保持；应用退出后再次使用需重新启用.")
                    }
                }

                if isWorking {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(progressText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("启用 JIT")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用或 Bundle ID")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || isWorking)
            }
        }
        .onAppear {
            if apps.isEmpty { Task { await load() } }
        }
        .alert("启用 JIT", isPresented: Binding(
            get: { confirmTarget != nil },
            set: { if !$0 { confirmTarget = nil } }
        )) {
            Button("取消", role: .cancel) { confirmTarget = nil }
            Button("启用", role: .destructive) {
                if let target = confirmTarget {
                    runJIT(target)
                }
                confirmTarget = nil
            }
        } message: {
            Text(confirmTarget.map { "为「\($0.name)」（\($0.bundleID)）启用 JIT？\n应用将以调试模式启动，当前界面会退到后台." } ?? "")
        }
        .alert("启用失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("JIT 已启用", isPresented: $showSuccess) {
            Button("好", role: .cancel) {}
        } message: {
            Text(successMessage)
        }
    }

    private func jitRow(_ app: JITAppInfo) -> some View {
        Button {
            confirmTarget = app
        } label: {
            HStack(spacing: 12) {
                JITAppIconView(bundleID: app.bundleID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(app.bundleID)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "bolt.fill")
                    .foregroundStyle(AppTheme.accent)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let apps = try await Task.detached(priority: .userInitiated) {
                try JITEnableService.shared.listJITCapableApps()
            }.value
            await MainActor.run { self.apps = apps }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func runJIT(_ app: JITAppInfo) {
        isWorking = true
        progressText = "正在建立隧道…"
        recordRecent(app.bundleID)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try JITEnableService.shared.enableJIT(bundleID: app.bundleID) { message in
                        Task { @MainActor in self.progressText = message }
                    }
                }.value
                await MainActor.run {
                    isWorking = false
                    successMessage = "「\(app.name)」已以调试模式启动，JIT 已生效.\n应用在运行期间保持 JIT；返回可继续操作."
                    showSuccess = true
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func recordRecent(_ bundleID: String) {
        recentBundleIDs.removeAll { $0 == bundleID }
        recentBundleIDs.insert(bundleID, at: 0)
        if recentBundleIDs.count > 5 {
            recentBundleIDs = Array(recentBundleIDs.prefix(5))
        }
        UserDefaults.standard.set(recentBundleIDs, forKey: "escape.jitRecents")
    }
}

/// App 图标行组件（「启用 JIT」/「拉起应用」共用）.
///
/// 优先用 SpringBoardServices 隧道图标（真实图标，第三方应用也能拿到），
/// 未加载完成 / 获取失败时回退灰色占位（app.dashed）.
/// 替换前用的进程内私有 API（supervisedAppIcon）对证书直装 / 侧载的
/// 第三方应用经常取不到图标 → 灰图标（v0.2.71 修复）.
struct JITAppIconView: View {
    let bundleID: String
    @State private var icon: UIImage?

    var body: some View {
        Group {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: bundleID) {
            guard icon == nil else { return }
            if let cached = JITAppIconLoader.shared.cached(for: bundleID) {
                icon = cached
                return
            }
            let img = await JITAppIconLoader.shared.load(bundleID: bundleID)
            if !Task.isCancelled {
                icon = img
            }
        }
    }
}
