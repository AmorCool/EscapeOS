import SwiftUI

/// 启用 JIT（汉化移植自 StikDebug）。
/// 列出签名带 get-task-allow 的应用，点击后以调试模式启动获得 JIT 权限。
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

    private var hasPairing: Bool { TunnelContext.shared.hasPairingFile }

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
                        Text("启用 JIT 需要：① 配对文件（在「应用」页导入）；② LocalDevVPN 已连接；③ 应用签名带 get-task-allow（证书直装签名默认带）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未找到可启用 JIT 的应用。")
                            .foregroundStyle(.secondary)
                        Text("只有签名带 get-task-allow（开发签名 / 证书直装）的应用才能启用 JIT；App Store 应用不适用。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ForEach(apps) { app in
                        Button {
                            confirmTarget = app
                        } label: {
                            HStack(spacing: 12) {
                                supervisedAppIcon(app.bundleID)
                                    .resizable()
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(app.bundleID)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Label("可启用 JIT 的应用", systemImage: "bolt.badge.a.fill")
                } footer: {
                    Text("点击应用后将以调试模式启动它（EscapeSpace 会退到后台）。JIT 权限在应用运行期间保持；应用退出后再次使用需重新启用。")
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
            Text(confirmTarget.map { "为「\($0.name)」（\($0.bundleID)）启用 JIT？\n应用将以调试模式启动，当前界面会退到后台。" } ?? "")
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
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try JITEnableService.shared.enableJIT(bundleID: app.bundleID) { message in
                        Task { @MainActor in self.progressText = message }
                    }
                }.value
                await MainActor.run {
                    isWorking = false
                    successMessage = "「\(app.name)」已以调试模式启动，JIT 已生效。\n应用在运行期间保持 JIT；返回 EscapeSpace 可继续操作。"
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
}
