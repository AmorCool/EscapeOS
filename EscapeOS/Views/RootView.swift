import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum MainTab: Hashable {
    case apps
    case reclaim
    case liveclean
    case gestalt
    case more
}

/// Top-level navigation: native SwiftUI tab bar + pairing onboarding.
struct RootView: View {
    @StateObject private var viewModel = AppListViewModel()
    @AppStorage("HasAcknowledgedLimits") private var hasAcknowledgedLimits = false
    @State private var selectedTab: MainTab = .apps
    @ObservedObject private var copyFeedback = CopyFeedback.shared

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
                ReclaimTabView(appList: viewModel)
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("空间回收", systemImage: "internaldrive")
            }
            .tag(MainTab.reclaim)

            NavigationView {
                LiveCleanTabView(appList: viewModel)
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("容器管理", systemImage: "shippingbox")
            }
            .tag(MainTab.liveclean)

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
            if hasAcknowledgedLimits {
                viewModel.reload()
            }
        }
        .onChange(of: hasAcknowledgedLimits) { acknowledged in
            if acknowledged {
                viewModel.reload()
            }
        }
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
    @State private var showWirelessPending = false

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
                // 真实配对引擎（host-pairing FFI）后续补齐，此处先展示入口与说明。
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
        .alert("iOS 27 无线配对", isPresented: $showWirelessPending) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("无线配对引擎将在补齐 host-pairing FFI 后启用（需 iOS 27 真机验证）。当前仍可经「导入配对文件」或「从剪贴板粘贴」完成设置。")
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [
                .item,
                .data,
                .content,
                .propertyList,
                .xml,
                .text,
                UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data) ?? .data
            ]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
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
                importError = error.localizedDescription
            }
        }
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

    /// Entry point for the iOS 27 wireless pairing flow.
    ///
    /// The real engine (host-pairing FFI) is deferred: the bundled
    /// `libidevice_ffi.a` (v0.1.5) does not expose a wireless-pairing host
    /// function, and iOS 27 is required to verify. When that FFI lands, call it
    /// here and surface the PIN via `pairPinCallback` as an in-app card
    /// (mirroring SideInstaller's `presentPin`), instead of a system notification.
    private func startWirelessPairing() {
        showWirelessPending = true
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
    @AppStorage("TunnelDeviceIP") private var tunnelIP: String = "10.7.0.1"

    var body: some View {
        Form {
            Section(header: Text("本地隧道"), footer: Text("必须与 LocalDevVPN 的隧道/设备 IP 一致。保持默认的 10.7.0.1，除非你修改过 LocalDevVPN。")) {
                TextField("设备 IP（默认 10.7.0.1）", text: $tunnelIP)
                    .keyboardType(.numbersAndPunctuation)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            Section {
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

            Section(header: Text("关于")) {
                Text(Self.aboutLine)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private static var aboutLine: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "EscapeSpace \(short) (\(build))"
    }
}
