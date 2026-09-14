import Foundation

/// 本机设备身份 —— 读序列号 / UDID / 机型，供 App Store 相关链路使用。
///
/// ## v0.3.402 改准：这条链路的**真正用途**只剩一个日志字段
///
/// 旧注释（v0.3.301）的说法是：Apple 的 `volumeStoreDownloadProduct` / `redownload`
/// 请求体里只有 `guid` 与 `serialNumber` 能标识"请求来自哪台设备"，必须传本机真序列号，
/// Apple 才能关联到**本机的 FairPlay 证书**、生成对本机有效的 `sinf` ——
/// 这是"下载加密包也能直接安装"的唯一前提。
///
/// **这个结论已在 v0.3.334 被真机实测推翻并回退**，本文件按代码事实改写：
///   · 三个请求构造器里的 `serialNumber` 现在**全部写死 `"0"`**：
///     `StoreDownloadEndpoint+Fetch.swift:290`、`VersionFinder.swift:158`、`VersionLookup.swift:146`。
///     （真机实测 v0.3.331：带本机真序列号时 volumeStore 回空包、redownload 回 HTTP 500，
///     链路根本走不下去；上游 ipatool / Asspp 也都是发 `"0"`。）
///   · 于是 `Configuration.deviceSerialNumber` 在整个 vendor 里**只被读 1 次**：
///     `Download.swift:123` 的一行日志（`serialNumber=\(...)`）。**它不进任何请求。**
///   · `fairPlayCertificate` / `fairPlayDeviceType` 这两个字段**全工程只写不读**
///     → v0.3.402 直接删除（连同读它们所需的第二次隧道）。
///
/// ## 因此本类型的定位
///
/// 「本机身份」的**进程内缓存读取**。读一次要建 RSD 隧道，真机实测**秒级**
/// （旁证：CHANGELOG 0.3.25x「此前在主线程同步建隧道会冻住设置页数秒」），
/// 所以：
///   · **绝不能放在下载启动这类关键路径上同步调用** —— 下载链路现在只调
///     `warmUpInBackground()` + `applyIfCached()`（两者都不等待隧道）；
///   · 一个 App 生命周期**只真正读一次**，之后全部走缓存；
///   · 读取通道收敛为**一次**隧道：只取 lockdown 根字典。
///     （v0.3.402 之前还会为上面两个没人读的 FairPlay 字段**再建一次**
///      `com.apple.mobile.iTunes` 域的隧道 —— 纯浪费。）
enum LocalDeviceIdentity {

    struct Snapshot {
        var serialNumber: String?
        var udid: String?
        var productType: String?

        /// 是否拿到了可用的本机身份
        var isUsable: Bool {
            !(serialNumber ?? "").isEmpty
        }

        var summary: String {
            let sn = serialNumber ?? "-"
            // 这里必须显示**下载实际会用的** guid。
            // 曾经显示的是从 UDID 派生的值（iOS 27 不给 UniqueDeviceIdentifier → 恒 `-`），
            // 与真正发出去的 `Configuration.deviceIdentifier` 不是同一个数，排查时误导。
            let actual = Configuration.deviceIdentifier
            let shown = actual.isEmpty ? "-" : String(actual.prefix(12)) + "…"
            return "序列号 \(sn) · guid \(shown) · \(productType ?? "-")"
        }
    }

    // MARK: - 进程内缓存

    /// 读一次要建隧道（秒级），所以整个 App 生命周期只真正读一次。
    ///
    /// 用 `NSLock` 而不是 `actor`：这里全是**同步** API（调用点 `load()` / `applyIfCached()`
    /// 都在同步上下文里），`actor` 满足不了。与 `AppStoreDownloadStore` 同款做法。
    private static let cacheLock = NSLock()
    private static var cached: Snapshot?
    /// 是否已经有一次**后台预取**在跑 —— 防止「连点两次下载」时并发建两轮隧道。
    private static var prefetching = false

    /// 缓存里的身份（**绝不建隧道**）；冷缓存返回 nil。
    static func cachedSnapshot() -> Snapshot? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cached
    }

    /// 手动失效（换设备 / 重连隧道 / 用户重置设备标识之后用）。
    static func invalidate() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cached = nil
        prefetching = false
    }

    /// 后台预热：把隧道建在**不阻塞任何人的地方**。
    ///
    /// 下载链路启动时调它一次 —— 首次下载因此**不等待**设备 IO；
    /// 之后 `load()` / `applyIfCached()` 全部命中缓存。
    ///
    /// **它绝不写 `Configuration.deviceSerialNumber`**：那个写只发生在调用方自己的任务里
    /// （见 `applyIfCached()` 的注释——跨线程写这个 `String` 全局量是有竞争的）。
    static func warmUpInBackground() {
        cacheLock.lock()
        // 已缓存、或已有一轮预取在跑 → 不重复建隧道（连点两次下载时尤其重要）
        if cached != nil || prefetching {
            cacheLock.unlock()
            return
        }
        prefetching = true
        cacheLock.unlock()
        Task.detached(priority: .utility) {
            _ = loadIntoCache()
        }
    }

    // MARK: - 读取

    /// 读本机身份并写入进程内缓存 —— **唯一真正建隧道的入口**。
    ///
    /// 不抛错：任何一步失败都返回已拿到的部分，让调用方继续（并靠日志暴露问题）。
    private static func loadIntoCache() -> Snapshot {
        if let hit = cachedSnapshot() { return hit }

        let started = Date()
        var s = Snapshot()
        if let root = try? DeviceInfoService.lockdownFullDict() {
            s.serialNumber = root["SerialNumber"] as? String
            s.udid = root["UniqueDeviceIdentifier"] as? String
            s.productType = root["ProductType"] as? String
        }
        // 变量名不用 `ms`：本类型里没有同名方法，但另一个文件的 `ms(since:)` 同名容易被误读
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        LoginLogger.shared.log("[本机] 读设备身份耗时 \(elapsedMs)ms（建 RSD 隧道 1 次，进程内只读一次）"
            + " · 序列号 \(s.serialNumber ?? "未取到")",
            category: .appStore)

        cacheLock.lock()
        // 读失败（隧道没起来等）**不写缓存** —— 免得把一次偶发失败固化一整个 App 生命周期；
        // 下次下载会再在后台试一次（与 v0.3.402 之前「每次下载都读」的自愈行为一致）。
        if s.isUsable { cached = s }
        prefetching = false
        cacheLock.unlock()
        return s
    }

    /// 读取本机身份（缓存命中 → 0 成本；未命中 → **会建隧道，秒级**）。
    ///
    /// ⚠️ 不要在下载启动这类关键路径上同步调用 —— 那里要用
    /// `warmUpInBackground()` + `applyIfCached()`。
    static func load() -> Snapshot {
        loadIntoCache()
    }

    /// 只在**缓存已热**时把序列号同步补进 `Configuration.deviceSerialNumber`
    /// （0 成本、不建隧道）。缓存冷 → 返回 nil，**什么都不做**。
    ///
    /// 为什么不用后台任务去写这个全局量：vendor 会在**下载任务**里读它
    /// （`Download.swift:123` 的那行日志），后台写 + 下载任务读是一对无保护的跨线程读写
    /// （`String` 非原子，retain/release 会有竞争）。这里由调用方在**自己的任务里**写，
    /// 写与读天然有序 —— 与 v0.3.402 之前 `apply()` 的行为等价，只是不再阻塞。
    ///
    /// 后果：**首次下载**（缓存还冷）那次的日志里 `serialNumber=` 会是默认的 `0`；
    /// 第二次起由本函数补上真值。这个字段不进请求，所以只影响可读性。
    @discardableResult
    static func applyIfCached() -> Snapshot? {
        guard let snap = cachedSnapshot() else { return nil }
        if let sn = snap.serialNumber, !sn.isEmpty {
            Configuration.deviceSerialNumber = sn
        }
        return snap
    }

    /// 下载请求实际会用的 guid（= 登录时用的那个持久化标识），用于日志对照
    static var downloadGUID: String { Configuration.deviceIdentifier }
}
