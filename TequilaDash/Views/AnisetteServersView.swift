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
    /// v0.3.613：用户自定义的 `X-MMe-Client-Info`（留空 = 用内置默认）.
    ///
    /// 为什么需要可自定义（依据 SideSign PR #5「Fix 2FA failing」，2026-10-13 merged）：
    /// GSA 现在会**指纹识别所用的 adi 库**，导致既有 anisette 服务器生成的 headers 被拒
    /// （用户侧表现就是 `Code -80045`）。SideSign 作者实测把 client info 换成
    /// `<Pixel 8><Android; 14; UQ1A.240205.004><com.apple.AuthKit/1 (com.apple.android.music/4.9.6)>`
    /// 就能让既有服务器恢复可用。但 GSA 的判据会再变，故**做成可编辑**，
    /// 与 SideStore 的 `customAnisetteClientInfo` 同款（它的优先级是
    /// 「UserDefaults 自定义 > 配置文件 > 默认值」，本仓取前两者）.
    @AppStorage("CustomAnisetteClientInfo") private var customClientInfo: String = ""
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

    /// 常用服务器 —— **直接取 `MemoryLimitSettings.anisetteServers`（15 个）**，不再另维护一份。
    ///
    /// v0.3.603 之前这里硬编码了 5 个（对照参考截图 5 的 AltStore Popular 列表），
    /// 而设置层 `MemoryLimitSettings.anisetteServers` 有 15 个（原有 4 + 合并 SideInstaller
    /// 社区列表 11）—— 两处不一致，用户 2026-10-13 报「原来几十个去哪里了」。
    /// **唯一真相源**：列表归 `MemoryLimitSettings`，本页只负责渲染。
    private static let popular: [PopularServer] = MemoryLimitSettings.anisetteServers.map { url in
        let host = MemoryLimitSettings.host(from: url)
        return PopularServer(name: host, url: url)
    }

    private static let defaultServer = "https://ani.stikstore.app"

    var body: some View {
        List {
            statusSection
            popularSection
            customSection
            clientInfoSection
            onDeviceSection
            resetSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Anisette 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            customText = Self.isPopular(anisetteServer) ? "" : MemoryLimitSettings.host(from: anisetteServer)
            await refreshStatus()
            // 自愈：开关已开但引擎缺件（上次下载失败 / 进程被杀）时，进入本页自动补装.
            // 不阻塞本页渲染 —— 引擎下载在 OnDeviceAnisetteManager 内部走 detached 后台任务.
            Task { await oda.installEngineIfNeeded() }
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

    // MARK: - Client Info

    /// SideSign 实测可用的 Android 形态 client info（PR #5，2026-10-13）.
    /// GSA 指纹识别 adi 库后，这个值能让既有 anisette 服务器恢复可用.
    private static let androidClientInfo =
        "<Pixel 8><Android; 14; UQ1A.240205.004><com.apple.AuthKit/1 (com.apple.android.music/4.9.6)>"

    private var clientInfoSection: some View {
        Section(header: Text("客户端标识"),
                footer: Text("发给 Apple 的 X-MMe-Client-Info.留空则用内置默认值.如果登录报 -80045，可试试点「填入 Android 形态」——该值经 SideSign 实测可绕过 GSA 对 adi 库的指纹识别.")) {
            HStack(spacing: 10) {
                TextField("留空 = 内置默认", text: $customClientInfo)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.footnote)
            }
            HStack {
                Text("当前生效")
                Spacer()
                Text(customClientInfo.isEmpty ? "内置默认" : "自定义")
                    .foregroundColor(.secondary)
            }
            Button("填入 Android 形态") {
                customClientInfo = Self.androidClientInfo
            }
            Button("恢复内置默认") {
                customClientInfo = ""
            }
            .foregroundColor(.secondary)
        }
    }

    // MARK: - 本机 Anisette

    private var onDeviceSection: some View {
        Section(header: Text("本机 Anisette"),
                footer: Text("本机 Anisette 在本机跑 ADI 模拟，不依赖 Anisette header 服务器，也不依赖设备配对文件.打开开关会自动从元数据地址下载并校验引擎；本机 ADI 取数尚未接线，就绪前后都会显式回退远程服务器.")) {
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
            engineRow
            // v0.3.620：本机 ADI 取数**已接线**（v0.3.613 起），这里按真实状态显示.
            // 旧文案「未接线（回退远程）」是 v0.3.613 之前的遗留，会让用户误以为功能没做.
            // 真实判据：`hasAdiPb`（有配给票据才可能走本机）+ `readiness()`.
            if oda.hasEngineInstalled {
                HStack {
                    Text("本机取数")
                    Spacer()
                    Text(localFetchStatus)
                        .foregroundColor(oda.readiness().isReady ? .secondary : .secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// 本机取数的真实状态（不再是固定的「未接线」）.
    private var localFetchStatus: String {
        switch oda.readiness() {
        case .off:
            return "未开启"
        case .notReady(let missing):
            return "未就绪（缺 \(missing.joined(separator: "、"))）"
        case .ready:
            return oda.hasAdiPb ? "本机生成（不连服务器）" : "首次需联网配给后转本机"
        }
    }

    /// ADI 引擎行：未安装显示「下载」；下载中显示进度；已安装显示版本 + 「移除」.
    @ViewBuilder
    private var engineRow: some View {
        if oda.isDownloading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在下载 ADI 引擎").foregroundColor(.secondary)
            }
        } else if oda.hasEngineInstalled {
            HStack {
                Text("ADI 引擎")
                Spacer()
                Text(oda.engineVersion.isEmpty ? "已安装" : "已安装 \(oda.engineVersion)")
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button {
                    AppHaptics.tap()
                    oda.removeEngine()
                } label: {
                    Text("移除").foregroundColor(AppTheme.danger)
                }
                .buttonStyle(.borderless)
            }
        } else {
            Button {
                AppHaptics.tap()
                Task { await oda.downloadEngine() }
            } label: {
                Text("下载 ADI 引擎")
            }
        }
        if let error = oda.lastError {
            Text(error)
                .font(.footnote)
                .foregroundColor(AppTheme.danger)
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
