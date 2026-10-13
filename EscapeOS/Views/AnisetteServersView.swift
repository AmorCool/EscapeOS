import Foundation
import SwiftUI

/// 「Anisette 服务器」二级页 —— 「更多 → 设置 → Anisette 服务器」点进来的下一级.
///
/// 对照 AltStore Classic 的 Remote AltServer 页（参考截图 5）分区：
///   · **Status**：当前服务器连通性（检测中 / 已连接 / 失败原因）；
///   · **常用**：常用服务器列表，选中打勾；
///   · **Custom**：自定义地址输入 + 打勾选用；
///   · **本机 Anisette**：ODA 模式开关 + 就绪状态 + 元数据源（详见 `OnDeviceAnisetteManager`）.
///
/// 说明文字一律用英文句点收尾；强调色统一 `AppTheme.accent`（不写死第二套蓝）.
struct AnisetteServersView: View {
    /// 与设置页、`AnisetteProvider` 同源的服务器键.
    @AppStorage("AnisetteServer") private var anisetteServer: String = "https://ani.stikstore.app"
    @ObservedObject private var oda = OnDeviceAnisetteManager.shared

    @State private var customText: String = ""
    @State private var status: Status = .checking
    @State private var statusTask: Task<Void, Never>?

    /// 服务器连通性检测结果.
    enum Status: Equatable {
        case checking
        case connected
        case failed(String)
    }

    /// 常用服务器（对照参考截图 5 的 Popular 列表）.
    private struct PopularServer: Identifiable {
        var id: String { url }
        let name: String
        let url: String
    }

    private static let popular: [PopularServer] = [
        PopularServer(name: "SideStore", url: "https://ani.sidestore.io"),
        PopularServer(name: "SideStore (.app)", url: "https://ani.sidestore.app"),
        PopularServer(name: "SideStore (.zip)", url: "https://ani.sidestore.zip"),
        PopularServer(name: "SideStore (.xyz)", url: "https://ani.846969.xyz"),
        PopularServer(name: "nythepegasus", url: "https://ani.npeg.us"),
    ]

    private static let defaultServer = "https://ani.stikstore.app"

    var body: some View {
        List {
            statusSection
            popularSection
            customSection
            onDeviceSection
            resetSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Anisette 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            customText = Self.isPopular(anisetteServer) ? "" : MemoryLimitSettings.host(from: anisetteServer)
            await refreshStatus()
        }
        .onDisappear { statusTask?.cancel() }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section(header: Text("状态")) {
            HStack {
                Text("状态")
                Spacer()
                statusLabel
            }
            Button {
                statusTask?.cancel()
                statusTask = Task { await refreshStatus() }
            } label: {
                Text("重新检测")
            }
            .disabled(status == .checking)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("检测中").foregroundColor(.secondary)
            }
        case .connected:
            HStack(spacing: 6) {
                Circle().fill(AppTheme.success).frame(width: 8, height: 8)
                Text("已连接").foregroundColor(.secondary)
            }
        case .failed(let reason):
            HStack(spacing: 6) {
                Circle().fill(AppTheme.danger).frame(width: 8, height: 8)
                Text(reason).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: - Popular

    private var popularSection: some View {
        Section(header: Text("常用")) {
            ForEach(Self.popular) { server in
                Button {
                    select(server.url)
                } label: {
                    serverRow(name: server.name, host: MemoryLimitSettings.host(from: server.url))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Custom

    private var customSection: some View {
        Section(header: Text("自定义"),
                footer: Text("填主机名或完整地址均可，留空表示不使用自定义地址.")) {
            HStack(spacing: 10) {
                TextField("ani.example.com", text: $customText)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.footnote)
                    .onSubmit { applyCustom() }
                Button {
                    applyCustom()
                } label: {
                    Image(systemName: customMatches ? "checkmark.circle.fill" : "checkmark.circle")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .disabled(normalizedCustom == nil)
                .accessibilityLabel("使用自定义地址")
            }
        }
    }

    // MARK: - 本机 Anisette

    private var onDeviceSection: some View {
        Section(header: Text("本机 Anisette"),
                footer: Text("本机 Anisette 在本机跑 ADI 模拟，不依赖 Anisette header 服务器，也不依赖设备配对文件.它仍需一个元数据地址来取引擎载荷；引擎缺件时会显式回退远程服务器.")) {
            Toggle("本机 Anisette", isOn: $oda.isEnabled)
            HStack {
                Text("就绪状态")
                Spacer()
                Text(oda.readinessText)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Text("元数据源")
                Spacer()
                Text(OnDeviceAnisetteManager.metadataHost)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 恢复默认

    private var resetSection: some View {
        Section {
            Button {
                select(Self.defaultServer)
            } label: {
                Text("恢复默认服务器（ani.stikstore.app）")
            }
        }
    }

    // MARK: - 行与动作

    private func serverRow(name: String, host: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundColor(.primary)
                Text(host).font(.footnote).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if host == MemoryLimitSettings.host(from: anisetteServer) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundColor(AppTheme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func select(_ url: String) {
        AppHaptics.tap()
        anisetteServer = url
        customText = Self.isPopular(url) ? "" : MemoryLimitSettings.host(from: url)
        statusTask?.cancel()
        statusTask = Task { await refreshStatus() }
    }

    private func applyCustom() {
        guard let url = normalizedCustom else { return }
        AppHaptics.tap()
        anisetteServer = url
        statusTask?.cancel()
        statusTask = Task { await refreshStatus() }
    }

    /// 把输入规整成完整 URL（缺 scheme 补 `https://`）；非法返回 nil.
    private var normalizedCustom: String? {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return nil }
        return withScheme
    }

    /// 输入是否正好等于当前选中的服务器.
    private var customMatches: Bool {
        guard let normalized = normalizedCustom else { return false }
        return normalized == anisetteServer
    }

    private static func isPopular(_ url: String) -> Bool {
        popular.contains { $0.url == url }
    }

    // MARK: - 连通性检测

    /// 探测当前服务器的 `/v3/client_info`：200 且含 `client_info` 字段即视为已连接.
    private func refreshStatus() async {
        status = .checking
        guard let base = URL(string: anisetteServer) else {
            status = .failed("地址无效")
            return
        }
        let url = base.appendingPathComponent("v3").appendingPathComponent("client_info")
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            if http == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               json["client_info"] != nil {
                status = .connected
            } else {
                status = .failed("HTTP \(http)")
            }
        } catch {
            status = .failed("连接失败")
        }
    }
}
