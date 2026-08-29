import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum MainTab: Hashable {
    case apps
    case reclaim
    case gestalt
    case more
}

/// Top-level navigation: native SwiftUI tab bar + pairing onboarding.
struct RootView: View {
    @StateObject private var viewModel = AppListViewModel()
    @AppStorage("HasAcknowledgedLimits") private var hasAcknowledgedLimits = false
    @State private var selectedTab: MainTab = .apps
    @ObservedObject private var copyFeedback = CopyFeedback.shared
    /// 全局 2FA 输入框：任何页面（含启动预热）触发的验证码请求都弹这里。
    @StateObject private var twoFactor = TwoFactorPromptCoordinator.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationView {
                appsContent
                    .navigationTitle("应用")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                viewModel.reload()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(viewModel.isLoading)
                        }
                    }
            }
            .tabItem {
                Label("应用", systemImage: "square.grid.2x2.fill")
            }
            .tag(MainTab.apps)

            NavigationView {
                SpaceReclaimView(appList: viewModel)
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("空间回收", systemImage: "internaldrive")
            }
            .tag(MainTab.reclaim)

            GestaltView()
                .tabItem {
                    Label("Gestalt", systemImage: "gearshape.2")
                }
                .tag(MainTab.gestalt)

            NavigationView {
                MoreView(appList: viewModel, onResetPairing: {
                    viewModel.resetPairing()
                    selectedTab = .apps
                })
            }
            .tabItem {
                Label("更多", systemImage: "ellipsis")
            }
            .tag(MainTab.more)
        }
        .overlay(CopyBanner(message: copyFeedback.message))
        .toolbarBackground(.visible, for: .tabBar)
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
            // 用户进入「IPA 侧载 / 证书管理」页时越可能已完成（幂等，内部有 guard）。
            viewModel.reload()
            warmUpAutoLogin()
        }
        .onChange(of: hasAcknowledgedLimits) { acknowledged in
            if acknowledged {
                viewModel.reload()
            }
        }
        // 全局 2FA 输入：后台预热 / 任何页面触发的验证码请求都在这里输入。
        // 标题标明来自哪个功能，避免用户不知道是谁在要验证码。
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
    /// 用户进入对应页面时无需再等十几秒的登录/列表加载。
    /// 只走免 2FA 的会话恢复与静默加载；失败不影响 app 正常使用。
    private func warmUpAutoLogin() {
        let settings = MemoryLimitSettings.shared
        guard settings.isLoggedIn, !settings.appleID.isEmpty else { return }
        IPAInstallService.shared.warmUp()
        CertificateManager.shared.warmUp()
    }

    @ViewBuilder
    private var appsContent: some View {
        if viewModel.isLoading && viewModel.apps.isEmpty && !viewModel.needsPairing {
            ProgressView("正在加载应用…")
        } else if viewModel.needsPairing {
            PairingSetupView(viewModel: viewModel)
        } else if let error = viewModel.errorMessage, viewModel.apps.isEmpty {
            ErrorStateView(message: error, onRetry: { viewModel.reload() })
        } else if viewModel.apps.isEmpty {
            EmptyStateView(diagnostics: "设备未返回任何用户应用。")
        } else {
            AppListView(viewModel: viewModel)
        }
    }
}

/// Shown when no pairing file is present: import + LocalDevVPN instructions.
struct PairingSetupView: View {
    @ObservedObject var viewModel: AppListViewModel
    @State private var showImporter = false
    @State private var importError: String?
    @State private var clipboardError: String?
    @State private var showWirelessPairing = false
    @State private var wirelessPin: String?
    @State private var wirelessStatus = "正在广播配对服务…"
    @State private var wirelessError: String?
    @State private var wirelessBroadcastErrorCode: Int?
    @State private var wirelessDeviceName: String?
    @State private var wirelessEngine: WirelessPairing?
    @AppStorage("keepAliveAudio") private var keepAliveAudio = false
    @AppStorage("keepAliveLocation") private var keepAliveLocation = false
    @State private var keepAlive = WirelessKeepAlive()

    // Observer tokens for `WirelessPairing`'s NSNotificationCenter callbacks.
    // We use notifications instead of block parameters because Swift's Clang
    // Importer silently drops bridged methods that have block parameters in
    // this toolchain (see WirelessPairing.h for details).
    @State private var wirelessPinObserver: NSObjectProtocol?
    @State private var wirelessCompleteObserver: NSObjectProtocol?
    @State private var wirelessBroadcastObserver: NSObjectProtocol?

    /// iOS 27 introduced in-app wireless pairing (the pairing code shows inside
    /// the app instead of via a system notification). Gate the wireless section on it.
    private var isIOS27OrLater: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)

                Text("一次性设置")
                    .font(.title2).bold()
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 14) {
                    SetupStep(number: 1, title: "安装 LocalDevVPN",
                               text: "从 App Store 安装 LocalDevVPN，保持设备 IP / 隧道 IP 为默认值（10.7.0.1），连接它并开启 Wi-Fi。")
                    SetupStep(number: 2, title: "获取配对文件",
                               text: "在 Windows 上用 iPASide 侧载。它会生成与 iLoader 相同类型的配对文件（USB 信任密钥 + 远程配对密钥），并自动放置 pairingFile.plist。也可以在这里导入 iLoader 文件。之后即可拔线——EscapeSpace 通过 LocalDevVPN 与本机通信，不走 USB。iOS 26.4+ 需要远程配对密钥；iOS 18 只需要 USB 信任部分。")
                    SetupStep(number: 3, title: "加载应用",
                               text: "EscapeSpace 随后列出你已安装的应用，可浏览或备份其数据。")
                }
                .padding(.horizontal)

                Button {
                    showImporter = true
                } label: {
                    Label("导入配对文件", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)

                Button {
                    importFromClipboard()
                } label: {
                    Label("从剪贴板粘贴配对文件", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal)

                if let importError = importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                if let clipboardError = clipboardError {
                    Text(clipboardError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                // iOS 27 无线配对（无需电脑）：配对码直接在 App 内显示，
                // 参考 SideInstaller 的 in-app PIN 卡片做法（原版 StikPair 用通知）。
                // 真实配对引擎已接入：si_run_host（Rust）经 WirelessPairing 桥接到本视图，
                // 配对文件写入 Documents/pairingFile.plist，TunnelContext 自动加载。
                if isIOS27OrLater {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("iOS 27 无线配对（无需电脑）", systemImage: "wifi")
                            .font(.headline)
                            .foregroundStyle(.blue)

                        Text("iOS 27 支持无线配对，且配对码会直接显示在 App 内（而不是系统通知）。点击「开始无线配对」后，在另一台设备的 设置 › 隐私与安全性 › 开发者模式 中选择「与 EscapeOS 配对」，并把此处显示的配对码输入到该设备即可完成。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Button {
                            startWirelessPairing()
                        } label: {
                            Label("开始无线配对", systemImage: "lock.iphone")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.blue)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .padding(.horizontal)
                }

                Button("我已经完成了 — 重试") {
                    viewModel.reload()
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
        .sheet(isPresented: $showWirelessPairing) {
            wirelessSheetContent
                .onDisappear {
                    // Reliable teardown: cancel the heartbeat timer + stop
                    // the Bonjour publish + drop the engine so the listener
                    // and NSNetService release deterministically (otherwise
                    // Bonjour registration can linger after the sheet closes,
                    // causing the "broadcast a while then disappears" symptom).
                    wirelessEngine?.stop()
                    wirelessEngine = nil
                    keepAlive.stop()
                    cancelWirelessPairingCleanup()
                }
        }
        .pairingFilePicker(isPresented: $showImporter) { result in
            switch result {
            case .success(let data):
                do {
                    let contents: String
                    if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
                        contents = utf8
                    } else if let xml = try? PropertyListSerialization.data(
                        fromPropertyList: try PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                        format: .xml,
                        options: 0
                    ), let text = String(data: xml, encoding: .utf8) {
                        contents = text
                    } else {
                        throw NSError(
                            domain: "EscapeOS",
                            code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "无法读取该配对文件。"]
                        )
                    }
                    try viewModel.importPairingFile(contents)
                    importError = nil
                    viewModel.reload()
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                // Don't treat user cancellation as an error surface.
                if (error as NSError).code == -4 { break }
                importError = error.localizedDescription
            }
        }
        .onAppear(perform: registerWirelessObservers)
        .onDisappear(perform: unregisterWirelessObservers)
    }

    /// Read a pairing file from the system pasteboard and import it.
    /// Reuses the same Data→String (plist fallback) parsing as the file importer.
    private func importFromClipboard() {
        guard let pasted = UIPasteboard.general.string,
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clipboardError = "剪贴板为空，或不含文本。"
            return
        }
        guard let data = pasted.data(using: .utf8) else {
            clipboardError = "剪贴板内容无法解析为配对文件。"
            return
        }
        do {
            try viewModel.importPairingFile(from: data)
            clipboardError = nil
            importError = nil
            viewModel.reload()
        } catch {
            clipboardError = error.localizedDescription
        }
    }

    /// Entry point for the iOS 27 device-initiated wireless pairing flow.
    ///
    /// Drives the real host-pairing engine (`si_run_host`, Rust, bridged via
    /// `WirelessPairing`): publishes the `_remotepairing-pairable-host._tcp`
    /// Bonjour service, shows the 6-digit PIN as an in-app card (mirroring
    /// SideInstaller's in-app PIN, not a system notification), and on success
    /// writes the resulting `RpPairingFile` to `Documents/pairingFile.plist`
    /// (the same path `TunnelContext` already loads), then reloads so the app
    /// picks up the new tunnel. The host's `alt_irk` is persisted in
    /// `UserDefaults` so an already-paired device keeps recognizing this host.
    private func startWirelessPairing() {
        wirelessPin = nil
        wirelessDeviceName = nil
        wirelessError = nil
        wirelessStatus = "正在广播配对服务（_remotepairing-pairable-host._tcp）…"
        showWirelessPairing = true

        // 若用户开启则启动后台保活，避免 Bonjour 注册被系统 SRP 回收。
        keepAlive.start(audio: keepAliveAudio, location: keepAliveLocation)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outPath = docs.appendingPathComponent("pairingFile.plist").path
        let storedAltIrk = UserDefaults.standard.string(forKey: "wirelessHostAltIrk")

        let pairing = WirelessPairing()
        wirelessEngine = pairing // keep alive for the blocking background call
        pairing.start(
            withHostName: "EscapeOS",
            model: "Mac17,7",
            outPath: outPath,
            storedAltIrk: storedAltIrk ?? ""
        )
        // PIN and completion are delivered via NSNotificationCenter; the
        // observer handlers are wired up on `onAppear`.
    }

    /// Closes the wireless-pairing sheet. The underlying host listener keeps
    /// running until the device connects or the app is killed; the sheet only
    /// closes the UI.
    private func cancelWirelessPairing() {
        showWirelessPairing = false
    }

    /// Reset all transient wireless-pairing state. Called from the sheet's
    /// `.onDisappear` so the next time the user opens the sheet we get a
    /// clean UI (no stale PIN, no leftover error message).
    private func cancelWirelessPairingCleanup() {
        wirelessPin = nil
        wirelessError = nil
        wirelessBroadcastErrorCode = nil
        wirelessBroadcastErrorCode = nil
        wirelessDeviceName = nil
        wirelessStatus = "正在广播配对服务…"
    }

    /// 后台保活开关卡片（移植自 StikPair）。
    private var keepAliveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("后台保活")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)

            Toggle("静默音频", isOn: $keepAliveAudio)
                .font(.subheadline)

            Toggle("位置更新", isOn: $keepAliveLocation)
                .font(.subheadline)

            Text("若广播过一会就消失，可开启其中一个或多个选项，让系统在后台继续保留本 App 的 Bonjour 注册。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Wireless pairing sheet content

    /// Extracted from `.sheet(...)` so we can attach `.onDisappear` reliably.
    /// NSNetService registrations on iOS 18 have been observed to linger
    /// past the sheet's lifecycle; the cleanup hook in `.onDisappear` makes
    /// sure the heartbeat + Bonjour publish are torn down deterministically.
    private var wirelessSheetContent: some View {
        NavigationView {
            VStack(spacing: 22) {
                Spacer(minLength: 8)
                if let error = wirelessError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                    Text("配对失败").font(.title3).bold()
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("关闭") {
                        cancelWirelessPairing()
                    }
                    .buttonStyle(.borderedProminent)
                } else if let name = wirelessDeviceName {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("配对成功").font(.title3).bold()
                    Text("已与 \(name) 建立无线配对。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("完成") {
                        cancelWirelessPairing()
                        viewModel.reload()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else if let pin = wirelessPin {
                    VStack(spacing: 10) {
                        Image(systemName: "lock.iphone")
                            .font(.system(size: 40))
                            .foregroundStyle(.blue)
                        Text("请输入配对码").font(.headline)
                        Text(pin)
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(.secondarySystemGroupedBackground))
                            )
                        Text("在另一台设备的 设置 › 隐私与安全性 › 开发者模式 中选择「与 EscapeOS 配对」，并输入上方配对码。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    // 进度态：菊花 + 状态文字垂直居中，keepAliveCard 贴底
                    //（v0.2.76 改：之前整个进度态一起被 Spacer 居中，
                    // keepAliveCard 较高把菊花+文字重心拉下，看起来偏下）。
                    Spacer(minLength: 8)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(wirelessStatus)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        if let code = wirelessBroadcastErrorCode {
                            Text("⚠️ 广播未确认（Bonjour code \(code)）")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                        }
                    }
                    Spacer(minLength: 8)
                    keepAliveCard
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .navigationTitle("iOS 27 无线配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancelWirelessPairing() }
                }
            }
        }
    }

    // MARK: - Wireless pairing NSNotificationCenter bridge

    private func registerWirelessObservers() {
        let center = NotificationCenter.default
        guard wirelessPinObserver == nil else { return }
        wirelessPinObserver = center.addObserver(
            forName: Notification.Name("WirelessPairingDidShowPINNotification"),
            object: nil,
            queue: .main
        ) { [self] note in
            guard let pin = note.userInfo?["pin"] as? String else { return }
            self.wirelessPin = pin
            self.wirelessStatus = "请在另一台设备输入以下配对码："
        }
        wirelessCompleteObserver = center.addObserver(
            forName: Notification.Name("WirelessPairingDidCompleteNotification"),
            object: nil,
            queue: .main
        ) { [self] note in
            guard let info = note.userInfo else { return }
            let success = (info["success"] as? NSNumber)?.boolValue ?? false
            let deviceName = (info["deviceName"] as? String) ?? ""
            let hostAltIrk = (info["hostAltIrk"] as? String) ?? ""
            let errorMsg = (info["error"] as? String) ?? ""
            if success {
                if !hostAltIrk.isEmpty {
                    UserDefaults.standard.set(hostAltIrk, forKey: "wirelessHostAltIrk")
                }
                self.wirelessDeviceName = deviceName.isEmpty ? "设备" : deviceName
                self.wirelessBroadcastErrorCode = nil
                self.keepAlive.stop()
            } else {
                self.wirelessError = errorMsg.isEmpty ? "配对失败，请重试。" : errorMsg
            }
        }
    }

    private func unregisterWirelessObservers() {
        let center = NotificationCenter.default
        if let t = wirelessPinObserver {
            center.removeObserver(t)
            wirelessPinObserver = nil
        }
        if let t = wirelessCompleteObserver {
            center.removeObserver(t)
            wirelessCompleteObserver = nil
        }
        if let t = wirelessBroadcastObserver {
            center.removeObserver(t)
            wirelessBroadcastObserver = nil
        }
        // 监听 Bonjour 广播失败（NSNetService didNotPublish）：
        // v0.2.76 之前只 NSLog，LiveContainer 共享应用 guest 等嵌入环境下
        // 静默失败让用户以为广播成功却搜不到——现在把错误码回报给 UI 提示。
        wirelessBroadcastObserver = center.addObserver(
            forName: Notification.Name("WirelessPairingDidFailBroadcastNotification"),
            object: nil,
            queue: .main
        ) { [self] note in
            if let code = note.userInfo?["code"] as? Int {
                self.wirelessBroadcastErrorCode = code
            }
        }
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
                        ? "\n\n提示：将 LocalDevVPN 重置为默认的 10.7.0.1 地址，保持 Wi-Fi 连接，并让 iPASide 放置配对文件（或在此导入）。iOS 26.5 上不需要自定义局域网 IP。"
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
    @AppStorage("TunnelDeviceIP") private var tunnelIP: String = "10.7.0.1"
    @AppStorage("AnisetteServer") private var anisetteServer: String = "https://ani.sidestore.io"
    @State private var shareTarget: ShareTarget?
    @State private var showNoPairingAlert = false
    @State private var showLoginSheet = false
    @State private var showAccountDetails = false
    /// v0.2.112：左上角登录日志入口（排查Apple 登录 / Anisette 失败用）。
    @State private var showLoginLog = false
    @AppStorage(KeepAliveManager.enabledKey) private var keepAliveEnabled = false

    var body: some View {
        Form {
            Section(header: Text("Apple ID 账户"), footer: Text("登录后，「增加内存限制」等功能可统一调用此账户。点眼睛图标可临时展开/隐藏账号详情，默认以星号保护隐私。")) {
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

            Section(header: Text("Anisette 服务器"), footer: Text("用于 Apple ID 设备认证（Anisette Data）。默认 ani.sidestore.io，可切换 StikStore / 846969 等备用服务器。")) {
                Picker("服务器", selection: $anisetteServer) {
                    ForEach(MemoryLimitSettings.anisetteServers, id: \.self) { server in
                        Text(MemoryLimitSettings.host(from: server)).tag(server)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(header: Text("本地隧道"), footer: Text("必须与 LocalDevVPN 的隧道/设备 IP 一致。保持默认的 10.7.0.1，除非你修改过 LocalDevVPN。")) {
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

            Section(header: Text("保活"), footer: Text("开启后，关闭本应用也会在后台保持运行（静音音频方式），让虚拟定位、无线配对广播等持续任务不中断。")) {
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
        // 左上角：登录日志查询入口。右上角「完成」由外层 MoreView 的 sheet 提供，
        // 这里只补 leading 位，两者 placement 不同不会互相覆盖。
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
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .alert("没有配对文件", isPresented: $showNoPairingAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("当前没有可导出的 pairingFile.plist。请先导入或生成配对文件。")
        }
    }

    private static var aboutLine: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "EscapeSpace \(short) (\(build))"
    }
}
