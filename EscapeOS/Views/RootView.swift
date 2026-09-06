import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum MainTab: Hashable {
    case home
    case gestalt
    case more
}

/// v0.3.197：顶部 Tab 重组 — 手机管家形态.
/// 原 5 tab（应用/空间回收/模块/Gestalt/更多）→ 3 tab：
/// 主页（空间回收 + 应用管理 + 模块 + 百宝箱卡片入口）/ Gestalt / 更多.
/// MoreView（原 More 页）保留备份/关于/设置等次要入口.
struct RootView: View {
    @StateObject private var viewModel = AppListViewModel()
    @AppStorage("HasAcknowledgedLimits") private var hasAcknowledgedLimits = false
    @State private var selectedTab: MainTab = .home
    @ObservedObject private var copyFeedback = CopyFeedback.shared
    /// 全局 2FA 输入框：任何页面（含启动预热）触发的验证码请求都弹这里.
    @StateObject private var twoFactor = TwoFactorPromptCoordinator.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            // v0.3.197：主页 — 手机管家形态
            NavigationStack {
                HomeView(appList: viewModel)
            }
            .tabItem {
                Label("主页", systemImage: "house.fill")
            }
            .tag(MainTab.home)

            GestaltView()
                .tabItem {
                    Label("Gestalt", systemImage: "gearshape.2")
                }
                .tag(MainTab.gestalt)

            NavigationStack {
                MoreView(appList: viewModel, onResetPairing: {
                    viewModel.resetPairing()
                    selectedTab = .home
                })
            }
            .tabItem {
                Label("更多", systemImage: "ellipsis")
            }
            .tag(MainTab.more)
        }
        .overlay(CopyBanner(message: copyFeedback.message))
        // 标签栏 / 导航栏的 Liquid Glass 外观由 EscapeSpaceApp.init() 统一配置
        // （UIAppearance 代理只对之后创建的实例生效，必须早于 UI 构建）.
        // 这里不要再接 `.toolbarBackground(.visible, for: .tabBar)` —— 它会给
        // 标签栏加一层不透明底板，把玻璃的透明材质与顶部高光整个盖掉.
        .sheet(isPresented: Binding(
            get: { !hasAcknowledgedLimits },
            set: { if !$0 { hasAcknowledgedLimits = true } }
        )) {
            LimitsDisclaimerView {
                hasAcknowledgedLimits = true
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            // 预热不等免责声明确认：免 2FA 的静默会话恢复，越早启动
            // 用户进入「IPA 侧载 / 证书管理」页时越可能已完成（幂等，内部有 guard）.
            viewModel.reload()
            warmUpAutoLogin()
        }
        .onChange(of: hasAcknowledgedLimits) { acknowledged in
            if acknowledged {
                viewModel.reload()
            }
        }
        // 全局 2FA 输入：后台预热 / 任何页面触发的验证码请求都在这里输入.
        // 标题标明来自哪个功能，避免用户不知道是谁在要验证码.
        .alert(
            "来自\(twoFactor.pending?.feature ?? "Apple ID")的 Apple ID 验证请求",
            isPresented: Binding(
                get: { twoFactor.pending != nil },
                set: { presented in
                    if !presented { twoFactor.cancel() }
                }
            )
        ) {
            TextField("6 位验证码", text: $twoFactor.code)
                .keyboardType(.numberPad)
            Button("登录") { twoFactor.submit() }
            Button("取消", role: .cancel) { twoFactor.cancel() }
        } message: {
            Text("输入您的 2FA 验证码以登录")
        }
    }

    /// app 启动后后台预热「IPA 侧载」与「证书管理」的 Apple ID 登录态，
    /// 用户进入对应页面时无需再等十几秒的登录/列表加载.
    /// 只走免 2FA 的会话恢复与静默加载；失败不影响 app 正常使用.
    private func warmUpAutoLogin() {
        let settings = MemoryLimitSettings.shared
        guard settings.isLoggedIn, !settings.appleID.isEmpty else { return }
        IPAInstallService.shared.warmUp()
        CertificateManager.shared.warmUp()
    }
}

struct SetupStep: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundColor(.secondary)
            }
        }
    }
}

/// Generic error state with retry, styled as a card to match the rest of the app.
struct ErrorStateView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                InfoActionCard(
                    icon: "exclamationmark.triangle.fill",
                    iconTint: .orange,
                    title: "出现问题",
                    message: message + (message.contains("tunnel") || message.contains("LocalDevVPN") || message.contains("Heartbeat")
                        ? "\n\n提示：将 LocalDevVPN 重置为默认的 10.7.0.1 地址，保持 Wi-Fi 连接，并让 iPASide 放置配对文件（或在此导入）.iOS 26.5 上不需要自定义局域网 IP."
                        : ""),
                    actionTitle: "重试",
                    action: onRetry
                )
                .padding(.horizontal)
            }
            .padding(.top, 24)
        }
    }
}

/// Shown when no user apps are discoverable.
struct EmptyStateView: View {
    let diagnostics: String

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                InfoActionCard(
                    icon: "square.grid.2x2",
                    title: "未找到应用",
                    message: diagnostics
                )
                .padding(.horizontal)
            }
            .padding(.top, 24)
        }
    }
}

/// Settings form embedded in the Settings tab.
struct SettingsForm: View {
    var onResetPairing: () -> Void
    @StateObject private var memorySettings = MemoryLimitSettings.shared
    /// v0.3.122：开发证书状态观察（创建成功/失败即时刷新 UI）
    @StateObject private var certStore = DeveloperCertStore.shared
    @State private var certTask: Task<Void, Never>?
    @State private var certError: String?
    @AppStorage("TunnelDeviceIP") private var tunnelIP: String = "10.7.0.1"
    @AppStorage("AnisetteServer") private var anisetteServer: String = "https://ani.stikstore.app"
    @State private var shareTarget: ShareTarget?
    @State private var showNoPairingAlert = false
    @State private var showLoginSheet = false
    @State private var showAccountDetails = false
    /// v0.2.112：左上角登录日志入口（排查Apple 登录 / Anisette 失败用）.
    @State private var showLoginLog = false
    @AppStorage(KeepAliveManager.enabledKey) private var keepAliveEnabled = false

    var body: some View {
        Form {
            Section(header: Text("Apple ID 账户"), footer: Text("登录后，部分功能可统一调用此账户.")) {
                if memorySettings.isLoggedIn {
                    HStack {
                        Text("账号")
                        Spacer()
                        Text(showAccountDetails ? memorySettings.appleID : memorySettings.maskedAppleID())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Button {
                            showAccountDetails.toggle()
                        } label: {
                            Image(systemName: showAccountDetails ? "eye.slash.fill" : "eye.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showAccountDetails ? "隐藏账号" : "显示账号")
                    }
                    if showAccountDetails {
                        HStack {
                            Text("凭证")
                            Spacer()
                            Text("Apple ID 密码已保存于钥匙串")
                                .foregroundColor(.secondary)
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Button("退出登录", role: .destructive) {
                        memorySettings.signOut()
                        showAccountDetails = false
                    }
                } else {
                    Button("登录 Apple ID") {
                        showLoginSheet = true
                    }
                }
            }

            // v0.3.122：开发证书（原生可拆卸模块的签名信任链）
            Section(header: Text("开发证书"), footer: Text("用已登录 Apple ID 的开发证书给原生模块签名.")) {
                if certStore.hasCert {
                    Label("证书已创建\(certStore.teamId.map { " · Team \($0)" } ?? "")",
                          systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Button {
                        certTask = Task { await runCertCreation() }
                    } label: {
                        if certStore.isBusy { ProgressView() } else { Text("重新创建证书") }
                    }
                    .disabled(certStore.isBusy)
                } else {
                    Label("尚未创建开发证书", systemImage: "seal")
                        .foregroundColor(.secondary)
                    Button {
                        certTask = Task { await runCertCreation() }
                    } label: {
                        if certStore.isBusy { ProgressView() } else { Text("创建开发证书") }
                    }
                    .disabled(certStore.isBusy)
                }
                Toggle("免 JIT 模式", isOn: Binding(
                    get: { certStore.jitFreeMode },
                    set: { certStore.jitFreeMode = $0 }))
            }

            Section(header: Text("Anisette 服务器"), footer: Text("用于 Apple ID 设备认证（Anisette Data）.")) {
                Picker("服务器", selection: $anisetteServer) {
                    ForEach(MemoryLimitSettings.anisetteServers, id: \.self) { server in
                        Text(MemoryLimitSettings.host(from: server)).tag(server)
                    }
                }
                .pickerStyle(.menu)
                Button("恢复默认服务器（ani.stikstore.app）") {
                    anisetteServer = "https://ani.stikstore.app"
                }
            }

            Section(header: Text("本地隧道"), footer: Text("必须与 LocalDevVPN 的隧道/设备 IP 一致.保持默认的 10.7.0.1，除非你修改过 LocalDevVPN.")) {
                TextField("设备 IP（默认 10.7.0.1）", text: $tunnelIP)
                    .keyboardType(.numbersAndPunctuation)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            Section(header: Text("配对文件")) {
                Button("导出配对文件") {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let url = docs.appendingPathComponent("pairingFile.plist")
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        showNoPairingAlert = true
                        return
                    }
                    shareTarget = ShareTarget(url: url)
                }

                Button("重置配对文件", role: .destructive) {
                    onResetPairing()
                }
            }

            Section(header: Text("限制")) {
                Text(ProductLimits.title)
                    .font(.headline)
                Text(ProductLimits.body)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("保活"), footer: Text("开启后，关闭本应用也会在后台保持运行.")) {
                Toggle("保持后台运行", isOn: $keepAliveEnabled)
                    .onChange(of: keepAliveEnabled) { _, enabled in
                        if enabled {
                            KeepAliveManager.shared.start()
                        } else {
                            KeepAliveManager.shared.stopIfNotRequested()
                        }
                    }
            }

            Section(header: Text("关于")) {
                Text(Self.aboutLine)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        // 左上角：登录日志查询入口.右上角「完成」由外层 MoreView 的 sheet 提供，
        // 这里只补 leading 位，两者 placement 不同不会互相覆盖.
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showLoginLog = true
                } label: {
                    Label("登录日志", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("登录日志")
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            AppleIDLoginSheet()
        }
        .sheet(isPresented: $showLoginLog) {
            LoginLogView()
        }
        .alert("证书创建失败", isPresented: Binding(
            get: { certError != nil },
            set: { if !$0 { certError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(certError ?? "")
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .alert("没有配对文件", isPresented: $showNoPairingAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("当前没有可导出的 pairingFile.plist.请先导入或生成配对文件.")
        }
    }

    /// v0.3.122：创建开发证书（错误不再吞掉——弹窗展示，1100 提示重新登录）
    private func runCertCreation() async {
        do {
            try await DeveloperCertStore.shared.createCertificateWithStoredAccount()
        } catch {
            let desc = (error as NSError).localizedDescription
            if desc.contains("1100") || desc.lowercased().contains("session has expired") {
                certError = "会话已过期，请在上方「Apple ID 账户」重新登录后再试"
            } else {
                certError = desc
            }
        }
    }

    private static var aboutLine: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "EscapeSpace \(short) (\(build))"
    }
}
