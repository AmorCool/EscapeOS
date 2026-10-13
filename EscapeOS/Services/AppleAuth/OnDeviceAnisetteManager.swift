import Foundation

/// 本机 Anisette（On-Device Anisette，ODA）模式管理器.
///
/// ## 机制（据 SideStore 源码 + 实测载荷，详见简报 §③）
/// SideStore 的 `AnisetteProvider.fetch()`（`SideStore/Core/Anisette/AnisetteProvider.swift`）
/// 按 `UserDefaults.standard.useOnDeviceAnisette` 分两条路：
///   · 关 → `fetchRemote`：把 `identifier` + `adi_pb` 发给远程 anisette 服务器取 headers；
///   · 开 → `OnDeviceAnisetteManager.shared.fetchAnisetteData()`：本地生成 headers.
/// 本地路径仍会**下载**一份元数据载荷（`AnisetteMode.remoteODA(sourceURL:fallbackURL:)`，
/// `sourceURL` 取服务器列表源、`fallbackURL` = `https://zzz.haus/oda.json`），
/// 解出 ADI 引擎库后在**本机**跑 ADI 模拟，故它**不依赖 anisette header 服务器**，
/// 但依赖那个元数据 URL 来取引擎载荷. 它**不依赖设备配对文件** ——
/// `grep -rn "pairing" SideStore/Core/Anisette/ SideStore/Core/Auth/` 命中为空.
///
/// ## 本仓现状（诚实边界）
/// 本仓**未内置** iOS 可加载的 ADI 引擎（全仓 `grep -rl "CoreADI\|storeservicescore"` 命中 0，
/// 也无 `AnisetteKit` / `SideSign` 依赖）. 实测 `https://zzz.haus/oda.json` 解出的两份库是
/// **ELF64 AArch64**（`libCoreADI.so` / `libstoreservicescore.so`），与 iOS 的 Mach-O 不可互换，
/// 无法直接加载. 故本开关的作用是**如实切换模式并做就绪检测**：开关开启但引擎缺件时，
/// `AnisetteProvider` 会**显式回退远程**并记录原因（绝不静默），等引擎就位后即可转本地.
///
/// Swift 6：本类无并发写风险（`@Published` 写全部来自主线程 UI；后台仅只读 Bool / 文件探测），
/// 与 `DeveloperCertStore` 同款范式，故 `shared` 走 `nonisolated(unsafe)`.
final class OnDeviceAnisetteManager: ObservableObject {
    nonisolated(unsafe) static let shared = OnDeviceAnisetteManager()

    /// 开关键. 沿用本仓「模块.项」点号惯例（与 `CellularTunnelManager.enabledKey` 同款）；
    /// 默认关（`UserDefaults` 无值即 `false`）⇒ 不开开关时引擎层零行为变化.
    static let enabledKey = "EscapeOS.OnDeviceAnisette"

    /// ODA 元数据源（ADI 引擎载荷 + 校验字段），对齐 SideStore
    /// `AppConstants.Anisette.defaultODAMetadataURL`（实测 = `https://zzz.haus/oda.json`）.
    static let metadataURL = "https://zzz.haus/oda.json"
    /// 元数据源主机（供 UI 展示）.
    static let metadataHost = "zzz.haus"

    /// 用户是否开启「本机 Anisette」（默认关）.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    // MARK: - 目录（对齐 SideStore 的 `.anisette` 隐藏目录命名）

    /// 引擎库目录（`libs`）.
    var engineDirectory: URL {
        Self.baseDirectory.appendingPathComponent("libs", isDirectory: true)
    }

    /// provisioning 目录.
    var provisioningDirectory: URL {
        Self.baseDirectory.appendingPathComponent("provisioning", isDirectory: true)
    }

    /// `Application Support/EscapeOS/.anisette`.
    private static var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("EscapeOS", isDirectory: true)
            .appendingPathComponent(".anisette", isDirectory: true)
    }

    // MARK: - 就绪检测

    /// 本机模式就绪状态.
    enum Readiness: Equatable {
        /// 开关未开.
        case off
        /// 开关已开但缺件（`missing` = 缺什么）.
        case notReady(missing: [String])
        /// 引擎与设备身份都就位.
        case ready

        var isReady: Bool { self == .ready }
    }

    /// 探测本机模式是否就绪. 判据全部是**可验证的实据**（文件存在性 / 钥匙串内容），
    /// 不是占位返回.
    func readiness() -> Readiness {
        guard isEnabled else { return .off }
        var missing: [String] = []
        if !Self.hasEngineLibraries() { missing.append("ADI 引擎库") }
        if !Self.hasDeviceIdentity() { missing.append("设备身份 identifier") }
        return missing.isEmpty ? .ready : .notReady(missing: missing)
    }

    /// 引擎库目录里是否同时存在 `libCoreADI` 与 `libstoreservicescore`（任意扩展名）.
    private static func hasEngineLibraries() -> Bool {
        let dir = OnDeviceAnisetteManager.shared.engineDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        let hasCore = names.contains { $0.hasPrefix("libCoreADI") }
        let hasStores = names.contains { $0.hasPrefix("libstoreservicescore") }
        return hasCore && hasStores
    }

    /// 钥匙串里是否有合法的 16 字节 `identifier`（本机模式的设备身份）.
    private static func hasDeviceIdentity() -> Bool {
        let keychain = EscapeKeychain(service: "com.ipaside.escapeos.memorylimit")
        guard let text = keychain.string(for: "identifier"),
              let data = Data(base64Encoded: text) else { return false }
        return data.count == 16
    }

    /// 就绪状态的可读文案（供 UI 展示）.
    var readinessText: String {
        switch readiness() {
        case .off:
            return "未开启"
        case .notReady(let missing):
            return "未就绪（缺 \(missing.joined(separator: "、"))）"
        case .ready:
            return "已就绪"
        }
    }

    // MARK: - 远程回退原因

    /// 供 `AnisetteProvider` 记录「本次为何回退远程」的可读原因；`nil` = 开关未开、无需说明.
    ///
    /// 本构建**未内置 ADI 取数实现**，故只要开关是开的，就一定有回退原因 ——
    /// 这样「开了本机 Anisette 却仍走远程」这件事在日志里是**显式**的，不会静默.
    var remoteFallbackReason: String? {
        switch readiness() {
        case .off:
            return nil
        case .notReady(let missing):
            return "本机 Anisette 已开启，但引擎未就绪（缺 \(missing.joined(separator: "、"))），本次显式回退远程服务器."
        case .ready:
            return "本机 Anisette 已开启且引擎就位，但本构建未内置 ADI 取数实现，本次显式回退远程服务器."
        }
    }
}
