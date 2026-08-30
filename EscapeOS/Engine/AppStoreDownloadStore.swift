import Foundation

/// App Store 账户的本地存储（凭据只写在本机 Documents，不上传）。
///
/// 与 EscapeOS 侧载用的 Apple ID 凭据是**两套独立命名空间**——
/// 侧载走开发者签名服务，这里走 App Store 下载，互不影响。
final class AppStoreDownloadStore {

    static let shared = AppStoreDownloadStore()
    private init() {
        Self.bootstrapDeviceIdentifier()
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
