import Foundation

/// App Store 账户的本地存储（凭据只写在本机 Documents，不上传）。
///
/// 与 EscapeOS 侧载用的 Apple ID 凭据是**两套独立命名空间**——
/// 侧载走开发者签名服务，这里走 App Store 下载，互不影响。
final class AppStoreDownloadStore {

    static let shared = AppStoreDownloadStore()
    private init() {
        Self.bootstrapDeviceIdentifier()
        Self.bootstrapSAPSigner()
    }

    /// 设置 ApplePackage 的机器标识（guid）。
    ///
    /// iOS 拿不到 MAC 地址（`DeviceIdentifier.system()` 永远 throw），而
    /// `Configuration.tlsConfiguration` 有一条
    /// `precondition(!deviceIdentifier.isEmpty)` —— 不设置就**一调用即崩溃**。
    ///
    /// 关键：这个值必须**持久化**。原版注释明确要求 "use random and save it"，
    /// 若每次冷启动都随机，等于每次换一台虚拟机器，Apple 会按多设备风控处理。
    private static func bootstrapDeviceIdentifier() {
        let key = "ApplePackageDeviceIdentifier"
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            Configuration.deviceIdentifier = saved
            return
        }
        let generated = DeviceIdentifier.random()
        defaults.set(generated, forKey: key)
        Configuration.deviceIdentifier = generated
    }

    /// v0.3.1：注入 SAP 签名器工厂（ApplePackage 只认 `SAPActionSigning` 抽象，
    /// 实现是本 app 的 `SapSigner`——Unicorn 解释执行 Apple 私有 CommerceKit 算
    /// `X-Apple-ActionSignature`，见 sapbridge/ 与 Services/AppleAuth/SapSigner.swift）。
    /// Apple 2026 年起认证请求缺此头 → 账号校验前直接 403（无论账号真假）。
    private static func bootstrapSAPSigner() {
        guard Configuration.sapSignerFactory == nil else { return }
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path
        Configuration.sapSignerFactory = { config in
            // v0.3.11：双模式——①局域网 PC 签名服务（EscapeSapServer.exe，无 JIT
            // 依赖、资产包在 PC 侧下载，绕开 iOS 磁盘配额）②本机模拟器（需 JIT）。
            // 填了服务器地址走远程；留空走本机。
            if let serverText = UserDefaults.standard.string(forKey: "SapServerURL"),
               !serverText.isEmpty,
               let serverURL = URL(string: serverText.trimmingCharacters(in: .whitespacesAndNewlines)),
               let scheme = serverURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                LoginLogger.shared.log("SAP 签名走远程服务器：\(serverURL.absoluteString)")
                LoginLogger.shared.log("远程初始化中（PC 首次需下载资产包，请耐心等待）…")
                let remote = try await RemoteSapSigner(baseURL: serverURL, config: config)
                LoginLogger.shared.log("远程签名器就绪")
                return remote
            }

            // 本机模式：Unicorn TCG = JIT（Apple 平台），无有效 JIT 权限时执行
            // 生成代码被内核签名检查杀（v0.3.8 .ips 实锤）。探测仅展示不拦截。
            let jitOK = SAPJITProbe.jitAvailable()
            SapStatusModel.shared.setJIT(jitOK ? .available : .unavailable)
            if !jitOK {
                LoginLogger.shared.log("SAP JIT 探测：未生效（仅供参考）——继续尝试初始化；若闪退请提供 .ips")
            }
            LoginLogger.shared.log("SAP 签名器初始化开始（缓存目录 \(cachesDir)）")
            SapProgressPoller.shared.start()
            defer { SapProgressPoller.shared.stop() }
            let signer = try SapSigner(
                setupURL: config.setupURL.absoluteString,
                certURL: config.certificateURL.absoluteString,
                version: Int32(truncatingIfNeeded: config.version),
                hardwareID: config.hardwareID,
                cacheDirectory: cachesDir
            )
            LoginLogger.shared.log("SAP 签名器初始化成功")
            return signer
        }
    }

    /// 下载目录（Documents/AppStoreDownloads，文件 App 可见）。
    var downloadsDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AppStoreDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("appstore_accounts.json")
    }

    private(set) var accounts: [AppStoreAccount] = []

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([AppStoreAccount].self, from: data) else {
            accounts = []
            return
        }
        accounts = list
    }

    func add(_ account: AppStoreAccount) {
        load()
        accounts.removeAll { $0.email == account.email }
        accounts.append(account)
        save()
    }

    func remove(_ email: String) {
        load()
        accounts.removeAll { $0.email == email }
        save()
    }

    func account(for email: String) -> AppStoreAccount? {
        if accounts.isEmpty { load() }
        return accounts.first { $0.email == email }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// v0.3.1：SapSigner 适配 ApplePackage 的 SAPActionSigning 抽象。
// sign(requestBody:) / close() 签名与 SapSigner 既有方法完全一致，直接空扩展即可。
extension SapSigner: SAPActionSigning {}
