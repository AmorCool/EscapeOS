import Foundation

/// App Store 账户的本地存储（凭据只写在本机 Documents，不上传）.
///
/// 与 EscapeOS 侧载用的 Apple ID 凭据是**两套独立命名空间**——
/// 侧载走开发者签名服务，这里走 App Store 下载，互不影响.
final class AppStoreDownloadStore {

    /// Swift 6 并发检查：本类型非 Sendable，但唯一的可变状态 `storedAccounts` 的
    /// **全部**读写都经 `lock`（NSRecursiveLock，见下方 `accounts` 访问器与各方法），
    /// 实例本身线程安全（注释已说明「detached 下载也会调用，读写需串行化」）。
    nonisolated(unsafe) static let shared = AppStoreDownloadStore()
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
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: "ApplePackageDeviceIdentifier")
        try? FileManager.default.removeItem(at: Self.documentsGUIDFile)
        Self.bootstrapDeviceIdentifier()
        LoginLogger.shared.log("App Store 设备标识已重置：\(Configuration.deviceIdentifier)"
            + "（已保存的会话属于旧身份，下次登录会不带旧会话）", category: .appStore)
    }

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("appstore_accounts.json")
    }

    // Calls also originate in detached downloads; serialize reads, writes and persistence.
    private let lock = NSRecursiveLock()
    private var storedAccounts: [AppStoreAccount] = []
    /// v0.3.570：最近一次 `load()` 是否**完整读出**了台账。
    /// `save()` 据此决定能不能回写 —— 读不全时绝不回写（否则会把没读到的账号覆盖掉）。
    private var lastLoadWritable = false
    private(set) var accounts: [AppStoreAccount] {
        get { lock.lock(); defer { lock.unlock() }; return storedAccounts }
        set { lock.lock(); defer { lock.unlock() }; storedAccounts = newValue }
    }

    /// 账号台账读取结果。
    ///
    /// `writable == false` = **这一次没能完整读出台账**（文件读不出 / JSON 整份坏 / 有记录解不出）。
    /// 调用方**必须只读、绝不回写** —— 否则会把没读到的账号当成「不存在」而覆盖掉。
    private struct AccountsLoad {
        let accounts: [AppStoreAccount]
        let writable: Bool
        let note: String?
        /// 面向用户的简短原因（写被拒时弹给用户看）；`writable == true` 时为 nil。
        let userReason: String?
    }

    /// 读盘并把结果装进内存。返回是否可写（`writable == false` 时任何写盘都必须被拒绝）。
    @discardableResult
    private func load() -> AccountsLoad {
        lock.lock(); defer { lock.unlock() }

        func finish(_ list: [AppStoreAccount], _ writable: Bool, _ note: String?,
                    _ userReason: String?) -> AccountsLoad {
            storedAccounts = list
            lastLoadWritable = writable
            return AccountsLoad(accounts: list, writable: writable, note: note, userReason: userReason)
        }

        // 文件确实不存在 = 合法空台账（首次运行 / 从没登录过），可以写。
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return finish([], true, nil, nil)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return finish([], false,
                          "账号台账存在但读取失败（被占用 / 磁盘错误），本次按只读处理，不回写",
                          "账号台账无法读取")
        }
        let dec = JSONDecoder()
        func migrate(_ list: [AppStoreAccount]) -> [AppStoreAccount] {
            list.map { account in
                var migrated = Self.normalized(account)
                if migrated.sessionRevision == nil { migrated.sessionRevision = UUID() }
                return migrated
            }
        }

        // 1) 快路径：整份解得出
        if let list = try? dec.decode([AppStoreAccount].self, from: data) {
            return finish(migrate(list), true, nil, nil)
        }

        // 2) 整份解失败 → **逐条**解，能救多少救多少（单条坏记录不再拖垮整份台账）。
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return finish([], false,
                          "账号台账 JSON 解析失败（文件损坏），本次按只读处理，不回写",
                          "账号台账文件损坏")
        }
        var salvaged: [AppStoreAccount] = []
        for element in raw {
            guard let d = try? JSONSerialization.data(withJSONObject: element),
                  let a = try? dec.decode(AppStoreAccount.self, from: d) else { continue }
            salvaged.append(a)
        }
        let migrated = migrate(salvaged)
        guard !migrated.isEmpty else {
            return finish([], false,
                          "账号台账 \(raw.count) 条全部无法解析，本次按只读处理，不回写",
                          "账号台账文件损坏")
        }
        // 有救回来的条目，但仍**不写盘**：写回会把解不出的那几条永久抹掉。
        return finish(migrated, false,
                      "账号台账 \(raw.count) 条里有 \(raw.count - migrated.count) 条无法解析，"
                          + "本次按只读处理，不回写（原文件保留）",
                      "账号台账文件损坏")
    }

    func add(_ account: AppStoreAccount) {
        lock.lock(); defer { lock.unlock() }
        let load = load()
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        var account = Self.normalized(account)
        account.sessionRevision = UUID()
        accounts.removeAll { $0.email.caseInsensitiveCompare(account.email) == .orderedSame }
        accounts.append(account)
        save()
        // v0.3.309：新登录的账号自动成为「当前下载账号」——多账号时用户刚登录的那个
        // 才是他想用来下载的；否则会沿用上一次的选择，出现"登录了却拿旧账号去下"。
        selectedEmail = account.email
    }

    // MARK: - v0.3.335：会话回写（这是「令牌很容易失效」的真因之一）

    /// 规范化 cookie 域（去掉前导点）后存储。
    ///
    /// `[Cookie].buildCookieHeader` 判域用的是
    /// `requestHost == domain || requestHost.hasSuffix("." + domain)` ——
    /// 存成 `.itunes.apple.com` 时，对 `p25-buy.itunes.apple.com`
    /// 既不等也不后缀命中，**cookie 会被整批丢弃**，请求就成了"未登录"（2034）。
    /// 而协议层每次 `mergeCookies(response.cookies)` 合并进来的
    /// `Cookie(copyFrom:)` 是**原样**取 `HTTPClient.Cookie.domain`（可能带点），
    /// 所以必须在**落盘前**统一规范化。
    static func normalized(_ account: AppStoreAccount) -> AppStoreAccount {
        var account = account
        account.cookie = account.cookie.map {
            var cookie = $0
            cookie.domain = StoreAuthenticationProtocol.storeCookieDomain(cookie.domain)
            return cookie
        }
        return account
    }

    /// 把请求过程中被 Apple 刷新过的账号（cookie / passwordToken / pod）写回存储。
    ///
    /// 购买与下载每次都会 `mergeCookies(response.cookies)` —— Apple 借 Set-Cookie
    /// 轮换会话票据。Asspp 的 `withAccount` 会把更新后的账号写回（`accounts[idx] = ...`），
    /// 我们此前只改本地 `var account` 副本、用完就丢，于是**每次都在拿旧票据去换新票据**，
    /// 表现为「动不动就要重登」。这里补上回写，且不改动当前选中账号。
    func update(_ account: AppStoreAccount) {
        lock.lock(); defer { lock.unlock() }
        let account = Self.normalized(account)
        guard let index = storedAccounts.firstIndex(where: { $0.email.caseInsensitiveCompare(account.email) == .orderedSame }),
              Self.sameSession(storedAccounts[index], account) else { return }
        storedAccounts[index] = account
        save()
    }

    /// Synchronous persistence: the next request must see the cookies just received.
    func updateFromAnyThread(_ account: AppStoreAccount) {
        update(account)
    }

    static func sameSession(_ lhs: AppStoreAccount, _ rhs: AppStoreAccount) -> Bool {
        lhs.email.caseInsensitiveCompare(rhs.email) == .orderedSame && lhs.sessionRevision == rhs.sessionRevision
            && lhs.passwordToken == rhs.passwordToken
            && lhs.directoryServicesIdentifier == rhs.directoryServicesIdentifier
    }

    /// Commit a refreshed session only if the account was not removed/replaced while awaiting Apple.
    /// Unlike add(), background refresh never changes the selected account or shop region.
    func commitRefresh(_ account: AppStoreAccount, replacing original: AppStoreAccount) throws -> AppStoreAccount {
        lock.lock(); defer { lock.unlock() }
        guard let index = storedAccounts.firstIndex(where: { $0.email.caseInsensitiveCompare(original.email) == .orderedSame }) else {
            throw StoreAuthenticationError.accountChanged
        }
        guard Self.sameSession(storedAccounts[index], original) else { return storedAccounts[index] }
        var refreshed = Self.normalized(account)
        refreshed.sessionRevision = UUID()
        storedAccounts[index] = refreshed
        save()
        return refreshed
    }

    func remove(_ email: String) {
        lock.lock(); defer { lock.unlock() }
        let load = load()
        guard load.writable else { logReadOnly(load.note); notifyWriteRejected(load.userReason); return }
        accounts.removeAll { $0.email.caseInsensitiveCompare(email) == .orderedSame }
        save()
    }

    func account(for email: String) -> AppStoreAccount? {
        lock.lock(); defer { lock.unlock() }
        if accounts.isEmpty { load() }
        return accounts.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
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
        lock.lock(); defer { lock.unlock() }
        if accounts.isEmpty { load() }
        return accounts.filter { Self.isUsable($0) }
    }

    /// 下载/安装实际使用的账号（选中账号失效时回退到第一个**可用**账号）
    var selectedAccount: AppStoreAccount? {
        lock.lock(); defer { lock.unlock() }
        if accounts.isEmpty { load() }
        if let e = selectedEmail, let hit = accounts.first(where: { $0.email.caseInsensitiveCompare(e) == .orderedSame }),
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
        lock.lock(); defer { lock.unlock() }
        remove(email)
        if selectedEmail?.caseInsensitiveCompare(email) == .orderedSame { selectedEmail = accounts.first?.email }
    }

    /// 退出全部账号
    func signOutAll() {
        lock.lock(); defer { lock.unlock() }
        accounts = []
        // 用户**显式**「退出全部账号」（确认弹窗，role: .destructive）—— 这是删除命令，
        // 不是「读失败当成空」。强制写空，因此台账损坏时也照常生效。
        save(force: true)
        selectedEmail = nil
    }

    /// 批量登录结果（供账号管理页展示）
    ///
    /// v0.3.570：`force == false` 时，只要最近一次 `load()` 没能**完整读出**台账，
    /// 就**不写盘**（否则会把没读到的账号覆盖掉）。`force` 仅用于用户显式「清空」类操作。
    private func save(force: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard force || lastLoadWritable else {
            logReadOnly("账号台账未完整读出，本次按只读处理，不回写")
            return
        }
        guard let data = try? JSONEncoder().encode(storedAccounts) else {
            LoginLogger.shared.log("[AppStore] 账号台账编码失败，未写盘（\(storedAccounts.count) 条）",
                                   category: .appStore)
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 写失败**不能静默**：调用方以为已持久化。
            LoginLogger.shared.log("[AppStore] 账号台账写盘失败：\(error)（\(storedAccounts.count) 条未持久化）",
                                   category: .appStore)
        }
    }

    /// 台账没完整读出来时的统一日志（说明本次为何只读、不回写）。
    private func logReadOnly(_ note: String?) {
        guard let note else { return }
        LoginLogger.shared.log("[AppStore] \(note)", category: .appStore)
    }

    /// 写被拒时给**用户可见**的反馈：日志不是反馈，用户改了却看不到变化会以为「点了没反应」。
    /// 文案点明原因与后果。`ToastCenter` 是 `@MainActor` 类，按全仓既有写法显式切回主 actor。
    ///
    /// 只在**用户直接发起**的写（`add` / `remove`）被拒时调用；后台会话刷新
    /// （`update` / `commitRefresh`）走 `save()` 的日志分支，不弹提示，免得下载过程中反复打扰。
    private func notifyWriteRejected(_ userReason: String?) {
        let reason = userReason ?? "账号台账读取异常"
        Task { @MainActor in
            ToastCenter.shared.show("\(reason)，本次改动未保存")
        }
    }
}
