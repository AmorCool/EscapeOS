import SwiftUI
import UniformTypeIdentifiers

private enum MainTab: Hashable {
    case apps
    case reclaim
    case liveclean
    case backups
    case settings
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

            NavigationView {
                BackupsListView(appList: viewModel)
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("备份", systemImage: "externaldrive.fill.badge.timemachine")
            }
            .tag(MainTab.backups)

            NavigationView {
                SettingsForm(onResetPairing: {
                    viewModel.resetPairing()
                    selectedTab = .apps
                })
                .navigationTitle("设置")
                .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(MainTab.settings)
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
                               text: "在 Windows 上用 iPASide 侧载。它会生成与 iLoader 相同类型的配对文件（USB 信任密钥 + 远程配对密钥），并自动放置 pairingFile.plist。也可以在这里导入 iLoader 文件。之后即可拔线——EscapeOS 通过 LocalDevVPN 与本机通信，不走 USB。iOS 26.4+ 需要远程配对密钥；iOS 18 只需要 USB 信任部分。")
                    SetupStep(number: 3, title: "加载应用",
                               text: "EscapeOS 随后列出你已安装的应用，可浏览或备份其数据。")
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

                if let importError = importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundColor(.red)
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

/// Generic error state with retry.
struct ErrorStateView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("出现问题")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if message.contains("tunnel") || message.contains("LocalDevVPN") || message.contains("Heartbeat") {
                Text("提示：将 LocalDevVPN 重置为默认的 10.7.0.1 地址，保持 Wi-Fi 连接，并让 iPASide 放置配对文件（或在此导入）。iOS 26.5 上不需要自定义局域网 IP。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button("重试", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

/// Shown when no user apps are discoverable.
struct EmptyStateView: View {
    let diagnostics: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("未找到应用")
                .font(.headline)
            Text(diagnostics)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

/// Settings form embedded in the Settings tab.
struct SettingsForm: View {
    var onResetPairing: () -> Void
    @AppStorage("TunnelDeviceIP") private var tunnelIP: String = "10.7.0.1"

    @State private var isProbing = false
    @State private var probeResult: String?

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

            Section(header: Text("诊断（调试用）"), footer: Text("仅用于验证 AppGroup 共享 App 沙盒逃逸是否在本机可用，普通用户无需理会。")) {
                Button {
                    runProbe()
                } label: {
                    if isProbing {
                        Label("探测中…", systemImage: "hourglass")
                    } else {
                        Label("AppGroup 探测", systemImage: "waveform")
                    }
                }
                .disabled(isProbing)

                if let result = probeResult {
                    Text(result)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxHeight: 360)
                }
            }
        }
    }

    // MARK: - AppGroup 探测（诊断）

    private func runProbe() {
        isProbing = true
        probeResult = nil
        Task {
            let report = await Task.detached { AppGroupProbe.run() }.value
            await MainActor.run {
                probeResult = report
                isProbing = false
            }
        }
    }

    private static var aboutLine: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "EscapeOS \(short) (\(build))"
    }
}
