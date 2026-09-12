import Foundation

/// App Store 账户的本地存储（凭据只写在本机 Documents，不上传）.
///
/// 与 EscapeOS 侧载用的 Apple ID 凭据是**两套独立命名空间**——
/// 侧载走开发者签名服务，这里走 App Store 下载，互不影响.
final class AppStoreDownloadStore {

    static let shared = AppStoreDownloadStore()
    private init() {
        // v0.3.171：账号区域注入（国区选 CN，见 storefront 与 2FA 短信渠道关联）
        Configuration.countryCode = UserDefaults.standard.string(forKey: "AppStore.CountryCode") ?? "US"
        Self.bootstrapDeviceIdentifier()
        // v0.3.307：**冷启动必须读盘**。此前只在 add/remove/account(for:) 里 load()，
        // 于是重启 App 后 `accounts` 一直是空数组 —— 商店显示「未登录」、「AppStore 下载」
        // 面板列不出账号，下载链路也会被误判成"没有账号"而回退到自备分发源（用户实测踩到）。
        load()
    }

    /// 设置 ApplePackage 的机器标识（guid）.
    ///
    /// iOS 拿不到 MAC 地址（`DeviceIdentifier.system()` 永远 throw），而
    /// `Configuration.tlsConfiguration` 有一条
    /// `precondition(!deviceIdentifier.isEmpty)` —— 不设置就**一调用即崩溃**.
    ///
    /// 关键：这个值必须**持久化**.原版注释明确要求 "use random and save it"，
    /// 若每次冷启动都随机，等于每次换一台虚拟机器，Apple 会按多设备风控处理.
    ///
    /// ⚠️ v0.3.330：**改存 Documents 的 `device_guid.txt`（不再只存 UserDefaults）**。
    /// 真机实锤：覆盖安装新版本后购买直接回 `failureType 2034` /
    /// `Sign In to the iTunes Store` —— 因为 UserDefaults 落在 Library/Preferences，
    /// **重装/覆盖安装会被重建**，而 Documents 下的 `appstore_accounts.json` 还在。
    /// 结果就是「账号还在、guid 却换了」，而 Apple 的会话
    /// （passwordToken / dsid / cookie）绑在旧 guid 上 → 被判失效。
    /// 存进 Documents 就能跟账号文件同生共死。
    private static func bootstrapDeviceIdentifier() {
        let legacyKey = "ApplePackageDeviceIdentifier"
        let file = documentsGUIDFile

        if let saved = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            Configuration.deviceIdentifier = saved
            return
        }
        // 迁移老版本存在 UserDefaults 里的值，避免升级后换身份
        if let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty {
            Configuration.deviceIdentifier = legacy
            try? legacy.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let generated = DeviceIdentifier.random()
        Configuration.deviceIdentifier = generated
        try? generated.write(to: file, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(generated, forKey: legacyKey)
    }

    /// guid 落盘位置（与 `appstore_accounts.json` 同目录）
    private static var documentsGUIDFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("device_guid.txt")
    }

    /// 下载目录（Documents/AppStoreDownloads，文件 App 可见）.
    var downloadsDirectory: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AppStoreDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// v0.3.167：重置 App Store 机器标识（guid）——删除持久化标识后重新随机生成.
    /// 用途：Apple 边缘对已标记的 guid 持续拒（native/fast 301/404）时换新身份.
    func resetDeviceIdentifier() {
        UserDefaults.standard.removeObject(forKey: "ApplePackageDeviceIdentifier")
        try? FileManager.default.removeItem(at: Self.documentsGUIDFile)
        Self.bootstrapDeviceIdentifier()
        LoginLogger.shared.log("App Store 设备标识已重置：\(Configuration.deviceIdentifier)", category: .appStore)
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
        // v0.3.309：新登录的账号自动成为「当前下载账号」——多账号时用户刚登录的那个
        // 才是他想用来下载的；否则会沿用上一次的选择，出现"登录了却拿旧账号去下"。
        selectedEmail = account.email
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

    // MARK: - v0.3.308：当前账号 / 账号管理

    /// 当前用于下载的账号邮箱（持久化）。
    /// 此前所有下载入口都硬取 `accounts.first`，多账号时无法切换、也没法退出登录。
    var selectedEmail: String? {
        get { UserDefaults.standard.string(forKey: "AppStore.SelectedEmail") }
        set { UserDefaults.standard.set(newValue, forKey: "AppStore.SelectedEmail") }
    }

    /// 账号是否可用：**必须同时有 dsid 与 passwordToken**.
    /// 缺任一项 Apple 就会把请求当未登录（`MZFinance.NoAccount_message`）；
    /// 这类账号（多为 v0.3.304~309 期间写下的坏记录）不能再参与下载。
    static func isUsable(_ a: AppStoreAccount) -> Bool {
        !a.directoryServicesIdentifier.isEmpty && !a.passwordToken.isEmpty
    }

    var usableAccounts: [AppStoreAccount] {
        if accounts.isEmpty { load() }
        return accounts.filter { Self.isUsable($0) }
    }

    /// 下载/安装实际使用的账号（选中账号失效时回退到第一个**可用**账号）
    var selectedAccount: AppStoreAccount? {
        if accounts.isEmpty { load() }
        if let e = selectedEmail, let hit = accounts.first(where: { $0.email == e }),
           Self.isUsable(hit) { return hit }
        return usableAccounts.first
    }

    func select(email: String) {
        selectedEmail = email
        // v0.3.328：切换当前下载账号后立刻把商店区域跟到这个账号，
        // 省得「换了账号、商店还停在旧区」。
        if let a = account(for: email) {
            AppStoreService.adoptAccountRegion(storefront: a.store, email: a.email)
        }
    }

    /// 退出登录单个账号
    func signOut(email: String) {
        remove(email)
        if selectedEmail == email { selectedEmail = accounts.first?.email }
    }

    /// 退出全部账号
    func signOutAll() {
        accounts = []
        save()
        selectedEmail = nil
    }

    /// 批量登录结果（供账号管理页展示）
    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
