import SwiftUI

/// 拉起应用（Launch Apps，汉化移植自 StikDebug 的 Other / Launch 标签页）。
/// 列出全部已安装应用（含系统应用），点击即以普通方式启动（不启用 JIT）。
struct LaunchAppsView: View {
    @State private var apps: [JITAppInfo] = []
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var searchText = ""
    @State private var launchingBundleIDs: Set<String> = []
    @State private var feedback: LaunchFeedback?

    private var hasPairing: Bool { TunnelContext.shared.hasPairingFile }

    private var filteredApps: [JITAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            if isLoading && apps.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("正在枚举已安装应用…")
                        Spacer()
                    }
                }
            } else if apps.isEmpty && !isLoading {
                Section {
                    if !hasPairing {
                        Label("未检测到配对文件", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("拉起应用需要：① 配对文件（在「应用」页导入）；② LocalDevVPN 已连接。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未获取到应用列表。")
                            .foregroundStyle(.secondary)
                        Text("点击右上角刷新重试；仍为空请确认 LocalDevVPN 已连接、配对文件有效。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                if !searchText.isEmpty && filteredApps.isEmpty {
                    Section {
                        Text("没有匹配的应用。")
                            .foregroundStyle(.secondary)
                        Text("换个名称或 Bundle ID 试试。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(filteredApps) { app in
                            launchRow(app)
                        }
                    } header: {
                        Label("全部应用", systemImage: "app.grid.3x3")
                    } footer: {
                        Text("点击应用即将其在前台拉起（普通启动，不启用 JIT）。")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("拉起应用")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用或 Bundle ID")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .onAppear {
            if apps.isEmpty { Task { await load() } }
        }
        .overlay(alignment: .bottom) {
            if let feedback {
                Text(feedback.message)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .foregroundStyle(feedback.success ? .green : .red)
                    .shadow(radius: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
        .alert("拉起失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func launchRow(_ app: JITAppInfo) -> some View {
        Button {
            launch(app)
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
                        .multilineTextAlignment(.leading)
                    Text(app.bundleID)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if launchingBundleIDs.contains(app.bundleID) {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(launchingBundleIDs.contains(app.bundleID))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let apps = try await Task.detached(priority: .userInitiated) {
                try JITEnableService.shared.listAllApps()
            }.value
            await MainActor.run { self.apps = apps }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func launch(_ app: JITAppInfo) {
        guard !launchingBundleIDs.contains(app.bundleID) else { return }
        launchingBundleIDs.insert(app.bundleID)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try JITEnableService.shared.launchApp(bundleID: app.bundleID)
                }.value
                await MainActor.run {
                    launchingBundleIDs.remove(app.bundleID)
                    showFeedback("「\(app.name)」已启动", success: true)
                }
            } catch {
                await MainActor.run {
                    launchingBundleIDs.remove(app.bundleID)
                    showFeedback("「\(app.name)」启动失败", success: false)
                }
            }
        }
    }

    private func showFeedback(_ message: String, success: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            feedback = LaunchFeedback(message: message, success: success)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                feedback = nil
            }
        }
    }
}

private struct LaunchFeedback: Identifiable {
    let id = UUID()
    let message: String
    let success: Bool
}
