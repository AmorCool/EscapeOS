import Foundation
import CryptoKit

/// 本机 Anisette（On-Device Anisette，ODA）模式管理器.
///
/// ## 机制（据 SideStore / SideSign 源码 + 实测载荷）
/// ODA 的开关分两条路：
///   · 关 → 远程：把 `identifier` + `adi_pb` 发给 anisette 服务器取 headers；
///   · 开 → 本机：下载一份**元数据载荷**（`https://zzz.haus/oda.json`），解出 ADI 引擎库，
///     在**本机**跑 ADI 模拟生成 headers. 故它**不依赖 anisette header 服务器**，
///     也不依赖设备配对文件（身份来自 16 字节 `identifier` + `adi.pb`）.
///
/// ## ADI 引擎库是什么（实测，2026-10-13）
/// `zzz.haus/oda.json` 的字段是 `{"s": <sha256>, "l": <base64>}`：
///   · `l` = 一个 ZIP 的 base64（解出 2609673 字节），内含且仅含两份库：
///       `libCoreADI.so`（2156064 字节）、`libstoreservicescore.so`（2388480 字节），
///       另有两份 `__MACOSX/._*` AppleDouble 边车（163 字节，需跳过）；
///   · `s` = `sha256(base64 载荷字符串 + "\n")`（实测逐字命中
///       `9d412b76953098ad5b4dccb9337e31652b9f29140ab2ec554bd9003ae226ee3f`）.
///   两份库的魔数都是 `7f 45 4c 46`（ELF），即 **ELF64 AArch64 Linux 共享库**.
///
/// ## 为什么能用（关键更正）
/// 旧版本这里写着「ELF 与 iOS 的 Mach-O 不可互换，无法直接加载」—— **这句是错的**.
/// ELF AArch64 不必被 iOS 的 `dlopen` 直接加载：它由 **Unicorn Engine 的 TCI 后端
/// 在进程内解释执行 AArch64 指令**（AnisetteKit 即此方案；无需 JIT 权限、无需调试器）.
/// 本仓**已经静态链接了 Unicorn TCI**（`project.yml` 的 `$(DERIVED_FILE_DIR)/SAP/lib/libunicorn.a`，
/// 现用于 SAP 的 x86-64 本地登录），故「引擎缺件」不是「引擎不可用」，而是**从未被下载安装过**.
///
/// ## 参考实现（本轮实证）
/// SideStore 的 `SideStore/Core/Anisette/OnDeviceAnisetteManager.swift` 只是薄壳，
/// 真逻辑在 SPM 依赖 **`SideSign`** 的 `Sources/Anisette/AnisetteDataManager.swift`
/// （`github.com/SideStore/SideSign`，main @ `6b68651697f99791ef85404b7aea1891a26a285d`）：
///   · 模式枚举 `AnisetteMode.remoteODA(sourceURL:fallbackURL:)`；
///   · `getClient(for:)` 的 `remoteODA` 分支：`createDirectory(libsDir)` 后，
///     **若 `validateLibrariesExist(libsDir)` 为假就自动 `setupFromRemote(...)`**
///     —— 即「进入该模式就确保引擎就位」，不是等用户去点按钮；
///   · `setupFromRemote` → `fetchODAInfo` → `downloadAndCacheLibs`：base64/URL 取 ZIP →
///     sha256 校验（**只记日志、不中断**）→ `unzipArchive` 到 libsDir → `validateLibrariesExist`.
/// 本类的「开关一开就自动装引擎」即对齐该 `remoteODA` 惰性安装语义.
///
/// ## 本类职责与诚实边界
/// 本类实现**引擎的获取与安装**：下载 `oda.json` → 解 base64 → 校验 `s` → 解压 → 校验两份库
/// 存在且为 ELF → 落盘到 `.anisette/libs`. 开关打开时**自动**执行（见 `installEngineIfNeeded()`），
/// 安装完成后 `readiness()` 变为就绪.
/// **仍未接线**的是「本机 ADI 取数」这一步 —— 即在 Unicorn 的 AArch64 解释器里加载这两份库、
/// 走 Apple 的 ADI 协议产出 headers（等价于移植 SideSign 的 `AnisetteDataManager` +
/// AnisetteKit 的 C++ `anisette_core_uc` / `EmulatorVM` / `elf_loader_emulator`）.
/// 卡点有二（均已实证，非推测）：
///   1. **Unicorn 架构**：本仓 `prepare.sap.py` 只编 `-DUNICORN_ARCH=x86`，AArch64 需另编
///      `-DUNICORN_ARCH=aarch64`（`project.yml` / 构建脚本属他人正在改，本轮不动）；
///   2. **许可**：AnisetteKit 为 **AGPLv3**（App Store 分发与闭源商用均被禁止），
///      其 C++ 取数层不能原样并入本宿主 App.
/// 故本类**不臆造**取数接口；在它接线之前，`AnisetteProvider` 对已就绪的本机模式仍会
/// **显式回退远程**并记录原因（绝不静默）.
///
/// Swift 6：本类无并发写风险（`@Published` 写全部来自主线程 UI；后台仅只读文件探测），
/// 与 `DeveloperCertStore` 同款范式，故 `shared` 走 `nonisolated(unsafe)`.
final class OnDeviceAnisetteManager: ObservableObject {
    nonisolated(unsafe) static let shared = OnDeviceAnisetteManager()

    /// 开关键. 沿用本仓「模块.项」点号惯例（与 `CellularTunnelManager.enabledKey` 同款）；
    /// 默认关（`UserDefaults` 无值即 `false`）⇒ 不开开关时引擎层零行为变化.
    static let enabledKey = "TequilaDash.OnDeviceAnisette"

    /// ODA 元数据源（ADI 引擎载荷 + 校验字段），对齐 SideStore
    /// `AppConstants.Anisette.defaultODAMetadataURL`（实测 = `https://zzz.haus/oda.json`）.
    static let metadataURL = "https://zzz.haus/oda.json"
    /// 元数据源主机（供 UI 展示）.
    static let metadataHost = "zzz.haus"

    /// 引擎载荷内的两份库文件名（与 `oda.json` 解出的 ZIP 内一致）.
    static let coreADIFileName = "libCoreADI.so"
    static let storesServicesFileName = "libstoreservicescore.so"

    /// 已安装引擎的元数据 sha256 持久化键（供跨启动显示版本）.
    private static let engineVersionKey = "TequilaDash.OnDeviceAnisette.EngineVersion"

    /// 用户是否开启「本机 Anisette」（默认关）.
    ///
    /// 打开时**自动**确保引擎就位（对齐 SideSign `remoteODA` 的惰性安装语义）：
    /// 若尚未安装且未在下载，就立刻起一个下载 —— 「未就绪（缺 ADI 引擎库）」因此
    /// 不再需要用户另找按钮.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { Self.scheduleAutoInstall() }
        }
    }

    /// 引擎是否正在下载（供 UI 显示进度并禁用按钮）.
    @Published private(set) var isDownloading = false
    /// 最近一次引擎操作失败原因（供 UI 显示）；成功或未操作为 `nil`.
    @Published private(set) var lastError: String?
    /// 已安装引擎的元数据 sha256 前缀（供 UI 展示）；未安装为空.
    @Published private(set) var engineVersion: String = ""

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        engineVersion = String((UserDefaults.standard.string(forKey: Self.engineVersionKey) ?? "").prefix(12))
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

    /// `Application Support/TequilaDash/.anisette`.
    private static var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("TequilaDash", isDirectory: true)
            .appendingPathComponent(".anisette", isDirectory: true)
    }

    // MARK: - 引擎获取与安装

    /// 引擎安装失败原因.
    enum EngineError: LocalizedError {
        case badMetadataURL
        case metadataHTTP(Int)
        case malformedMetadata
        case malformedPayload
        case missingLibrary(String)
        case notELF(String)
        case unzipFailed(String)

        var errorDescription: String? {
            switch self {
            case .badMetadataURL:
                return "元数据地址无效."
            case .metadataHTTP(let code):
                return "元数据源返回 HTTP \(code)."
            case .malformedMetadata:
                return "元数据格式无法识别（缺 s / l 字段）."
            case .malformedPayload:
                return "引擎载荷既不是 base64 也不是 ZIP."
            case .missingLibrary(let name):
                return "解压后缺少引擎库 \(name)."
            case .notELF(let name):
                return "\(name) 不是 ELF 引擎库."
            case .unzipFailed(let detail):
                return "引擎载荷解压失败：\(detail)"
            }
        }
    }

    /// 一次成功安装的产物（供 `Task.detached` 跨隔离域回传）.
    private struct InstalledEngine: Sendable {
        let sha256: String
        let files: [String]
    }

    /// 下载并安装 ADI 引擎. 全程：拉元数据 → 解出载荷 → 校验 `s` → 解压两份库 → 校验 ELF 魔数.
    ///
    /// 网络与解压放到 `Task.detached` 后台执行，只有 `@Published` 状态回主线程写，避免卡 UI.
    @MainActor
    func downloadEngine() async {
        guard !isDownloading else { return }
        isDownloading = true
        lastError = nil
        defer { isDownloading = false }
        let directory = engineDirectory
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await Self.fetchAndInstallEngine(into: directory)
            }.value
            UserDefaults.standard.set(result.sha256, forKey: Self.engineVersionKey)
            engineVersion = String(result.sha256.prefix(12))
            LoginLogger.shared.log(
                "[本机Anisette] ADI 引擎已安装：\(result.files.joined(separator: "、"))，sha256=\(result.sha256.prefix(12))…",
                category: .appleID)
        } catch {
            lastError = error.localizedDescription
            LoginLogger.shared.log("[本机Anisette] ADI 引擎安装失败：\(error.localizedDescription)", category: .appleID)
        }
    }

    /// 引擎未安装且未在下载时，**自动下载安装**（供开关打开 / 进入本机模式时调用）.
    ///
    /// 对齐 SideSign `AnisetteDataManager.getClient(for:)` 的 `remoteODA` 分支：该分支在
    /// 进入 ODA 模式且 `validateLibrariesExist` 失败时自动 `setupFromRemote` —— 即
    /// 「进入该模式就确保引擎就位」，而非等用户去点按钮. 本仓据此把「怎么补」做成**自动**：
    /// 开关一打开就装；装好后 `readiness()` 由 `未就绪（缺 ADI 引擎库）` 变为 `引擎已就绪`.
    @MainActor
    func installEngineIfNeeded() async {
        guard isEnabled, !isDownloading, !hasEngineInstalled else { return }
        LoginLogger.shared.log("[本机Anisette] 引擎未安装，自动开始下载安装", category: .appleID)
        await downloadEngine()
    }

    /// 把「自动安装」安全投递到主线程. `didSet` 是 `nonisolated`，不能在其中直接跨域调用
    /// `@MainActor` 方法，故经 `Task { @MainActor in … }` 显式跳到主线程再执行.
    private static func scheduleAutoInstall() {
        Task { @MainActor in
            await Self.shared.installEngineIfNeeded()
        }
    }

    /// 移除已安装的引擎（回到「未下载」状态）.
    @MainActor
    func removeEngine() {
        try? FileManager.default.removeItem(at: engineDirectory)
        UserDefaults.standard.removeObject(forKey: Self.engineVersionKey)
        engineVersion = ""
        lastError = nil
        LoginLogger.shared.log("[本机Anisette] ADI 引擎已移除", category: .appleID)
    }

    /// 引擎库是否已安装（供 UI 决定显示「下载」还是「移除」）.
    var hasEngineInstalled: Bool { Self.hasEngineLibraries() }

    // MARK: - 引擎下载流水线（后台执行）

    /// 长超时 session：元数据约 3.4 MB，实测在慢网络下耗时可达 90s 以上.
    nonisolated(unsafe) private static let engineSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    private nonisolated static func fetchAndInstallEngine(into directory: URL) async throws -> InstalledEngine {
        let meta = try await fetchMetadata()
        // `resolvePayload(_:)` 形参是非可选 `String`，而 `meta.payload` 是 `String?`
        // ⇒ 必须先解包（CI 报的正是这一行：value of optional type 'String?' must be unwrapped）。
        guard let rawPayload = meta.payload, !rawPayload.isEmpty else {
            throw EngineError.malformedMetadata
        }
        let (zipData, base64String) = try await resolvePayload(rawPayload)

        // sha256 校验：`s` = sha256(base64 载荷 + "\n")（实测确认）.
        // 对齐 SideSign：不匹配只记日志、不中断 —— 最终以解压出的库文件（存在 + ELF 魔数）为准.
        //
        // 用显式绑定名（`let b64 = base64String`）而不是 `let base64String` 简写：
        // CI 上后者报「value of optional type 'String?' must be unwrapped」
        // （简写在部分工具链 / 与同名形参共存时会退化为恒真绑定）。
        if let expected = meta.sha, let b64 = base64String {
            let actual = SHA256.hash(data: Data((b64 + "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            if actual != expected.lowercased() {
                LoginLogger.shared.log(
                    "[本机Anisette] 引擎载荷 sha256 不匹配（期望 \(expected.prefix(12))… 实际 \(actual.prefix(12))…），继续安装",
                    category: .appleID)
            }
        }

        let entries: [ZipEntry]
        do {
            entries = try ZipContainer.open(container: zipData)
        } catch {
            throw EngineError.unzipFailed(error.localizedDescription)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var installed: [String] = []
        for entry in entries {
            let name = entry.info.name
            // 跳过 macOS 的 AppleDouble 边车（`__MACOSX/._*`），它们不是库.
            if name.hasPrefix("__MACOSX/") { continue }
            let leaf = (name as NSString).lastPathComponent
            guard leaf == coreADIFileName || leaf == storesServicesFileName else { continue }
            guard let payload = entry.data, !payload.isEmpty else { continue }
            try payload.write(to: directory.appendingPathComponent(leaf), options: .atomic)
            installed.append(leaf)
        }

        // 两份库必须齐全，且都是 ELF（`7f 45 4c 46`）.
        for required in [coreADIFileName, storesServicesFileName] {
            let url = directory.appendingPathComponent(required)
            guard fm.fileExists(atPath: url.path) else { throw EngineError.missingLibrary(required) }
            guard isELF(url) else { throw EngineError.notELF(required) }
        }
        return InstalledEngine(sha256: meta.sha ?? "", files: installed)
    }

    /// 拉取并解析 `oda.json`. 兼容两种形态：顶层即 `{s,l}`，或 `{..., "oda":{s,l}}`.
    private nonisolated static func fetchMetadata() async throws -> ODAMetadata {
        guard let url = URL(string: metadataURL) else { throw EngineError.badMetadataURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await engineSession.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard http == 200 else { throw EngineError.metadataHTTP(http) }
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(ODAMetadata.self, from: data), direct.payload != nil {
            return direct
        }
        if let wrapper = try? decoder.decode(ODAMetadataWrapper.self, from: data), let oda = wrapper.oda {
            return oda
        }
        throw EngineError.malformedMetadata
    }

    /// 把 `l` 字段解析成 ZIP 数据：`http(s)` 前缀视为 URL（可能是 base64 文本或原始 ZIP），
    /// 否则按 base64 解码. 同时回传原始 base64 字符串（供 sha256 校验；URL 形态下为 nil）.
    private nonisolated static func resolvePayload(_ payload: String) async throws -> (zip: Data, base64: String?) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            guard let url = URL(string: trimmed) else { throw EngineError.malformedMetadata }
            let (data, response) = try await engineSession.data(from: url)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard http == 200 else { throw EngineError.metadataHTTP(http) }
            if data.starts(with: [0x50, 0x4B]) { return (data, nil) }
            if let text = String(data: data, encoding: .utf8),
               let zip = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (zip, text)
            }
            throw EngineError.malformedPayload
        }
        guard let zip = Data(base64Encoded: trimmed) else { throw EngineError.malformedPayload }
        return (zip, trimmed)
    }

    /// 读文件头 4 字节判 ELF 魔数（`7f 45 4c 46`）.
    private nonisolated static func isELF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? nil
        return head == Data([0x7F, 0x45, 0x4C, 0x46])
    }

    /// ODA 元数据. 键名兼容 SideSign 的 `ODAInfo`：`s` / `sha` / `sha256`，`l` / `payload` / `data` / `libraries` / `url`.
    private struct ODAMetadata: Decodable {
        let sha: String?
        let payload: String?

        enum CodingKeys: String, CodingKey {
            case s, sha, sha256
            case l, payload, data, libraries, url
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // 拆成多步：CI 上链式 `??` 太长会报
            // 「the compiler is unable to type-check this expression in reasonable time」
            // —— 编译器自己建议「break up the expression into distinct sub-expressions」。
            let shaA = try c.decodeIfPresent(String.self, forKey: .s)
            let shaB = try c.decodeIfPresent(String.self, forKey: .sha)
            let shaC = try c.decodeIfPresent(String.self, forKey: .sha256)
            sha = shaA ?? shaB ?? shaC

            let p1 = try c.decodeIfPresent(String.self, forKey: .l)
            let p2 = try c.decodeIfPresent(String.self, forKey: .payload)
            let p3 = try c.decodeIfPresent(String.self, forKey: .data)
            let p4 = try c.decodeIfPresent(String.self, forKey: .libraries)
            let p5 = try c.decodeIfPresent(String.self, forKey: .url)
            payload = p1 ?? p2 ?? p3 ?? p4 ?? p5
        }
    }

    /// 服务器列表形态的外层（`{"servers":[…],"oda":{…}}`）.
    private struct ODAMetadataWrapper: Decodable {
        let oda: ODAMetadata?
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
        let keychain = EscapeKeychain(service: "com.ipaside.tequiladash.memorylimit")
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
            return "引擎已就绪"
        }
    }

    // MARK: - 远程回退原因

    /// 供 `AnisetteProvider` 记录「本次为何回退远程」的可读原因；`nil` = 开关未开、无需说明.
    ///
    /// 本构建的「本机 ADI 取数」尚未接线，故只要开关是开的，就一定有回退原因 ——
    /// 这样「开了本机 Anisette 却仍走远程」这件事在日志里是**显式**的，不会静默.
    var remoteFallbackReason: String? {
        switch readiness() {
        case .off:
            return nil
        case .notReady(let missing):
            return "本机 Anisette 已开启，但引擎未就绪（缺 \(missing.joined(separator: "、"))），本次显式回退远程服务器."
        case .ready:
            return "本机 Anisette 已开启且 ADI 引擎已安装，但本机 ADI 取数尚未接线，本次显式回退远程服务器."
        }
    }
}
