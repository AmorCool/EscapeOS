import SwiftUI
import UIKit

/// 拉起应用（Launch Apps，汉化移植自 StikDebug 的 Other / Launch 标签页）.
/// 列出全部已安装应用（含系统应用），点击即以普通方式启动（不启用 JIT）.
///
/// 布局（本轮）：**布局 E（自适应网格）** —— 应用是「尺寸一致的图标条目流」，用 `AppAdaptiveGrid`
/// 按最小宽度自动决定列数（横竖屏 / 不同机型都铺满），比一列横条更像「启动台」；每格带阶梯入场动画.
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading && apps.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("正在枚举已安装应用…")
                        Spacer()
                    }
                    .padding(.vertical, 40)
                } else if apps.isEmpty && !isLoading {
                    if !hasPairing {
                        PairingGuideCard(showsBackground: false, note: "拉起应用还需要 LocalDevVPN 已连接.")
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("未获取到应用列表.")
                                .foregroundStyle(.secondary)
                            Text("点击右上角刷新重试；仍为空请确认 LocalDevVPN 已连接、配对文件有效.")
                                .font(AppFont.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !searchText.isEmpty && filteredApps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("没有匹配的应用.")
                            .foregroundStyle(.secondary)
                        Text("换个名称或 Bundle ID 试试.")
                            .font(AppFont.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    AppSectionHeader("全部应用",
                                     subtitle: "共 \(filteredApps.count) 个",
                                     symbol: "app.grid.3x3")
                    AppAdaptiveGrid(items: filteredApps, minimum: 92, spacing: 12) { app in
                        launchTile(app)
                    }
                    Text("点击应用即将其在前台拉起（普通启动，不启用 JIT）.")
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("拉起应用")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用或 Bundle ID")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    AppHaptics.tap()
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

    /// 自适应网格里的应用格子（布局 E）：大图标 + 名称居中，点击拉起；拉起中盖一层毛玻璃 + 转圈.
    private func launchTile(_ app: JITAppInfo) -> some View {
        Button {
            AppHaptics.tap()
            launch(app)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    JITAppIconView(bundleID: app.bundleID, size: 60)
                    if launchingBundleIDs.contains(app.bundleID) {
                        RoundedRectangle(cornerRadius: 60 * (8.0 / 36.0), style: .continuous)
                            .fill(.ultraThinMaterial)
                            .frame(width: 60, height: 60)
                        ProgressView()
                    }
                }
                Text(app.name)
                    .font(AppFont.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .appPressable(scale: 0.94)
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
