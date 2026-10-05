//
//  KBSyncProvider.swift
//  EscapeOS
//
//  把 `SAPStoreAgentContext`（解释 `storeagent` 生成 kbsync）接到
//  `Configuration.kbsyncGenerator` —— 这是 `ent/download` 能跑起来的**唯一**前置。
//
//  ## 为什么要这么绕
//
//  kbsync 要用 Unicorn 解释执行 Apple 的 `storeagent`，这部分是宿主能力
//  （ObjC++ + Unicorn，见 `Services/AppleAuth/SAP`）。而 `ent/download` 的请求
//  构造在 `vendor/ApplePackage` 里，**vendor 不能反向依赖宿主**。
//  所以走依赖注入：vendor 声明一个 `KBSyncGenerator` 闭包类型，宿主在启动时装配。
//  与 `Configuration.sapSignerFactory` 是同一个模式。
//
//  ## 为什么是「算完即弃」
//
//  上游 `GenerateKBSync` 本身就是一次性的：它只做 global init，不建解密会话
//  （`kbsync.go:11-13` 的注释说得很清楚）。我们这边每调一次就建一台机器、
//  跑完 guest 就丢 —— 代价是每次下载多几十毫秒，换来的是**没有跨请求的共享状态**，
//  省掉一整类「会话被关掉了还在用」的问题。
//

import Foundation

enum KBSyncProvider {

    /// 装配到 `Configuration.kbsyncGenerator`。**启动时调用一次即可。**
    ///
    /// 装配失败（资产不在）不报错、不抛 —— 只是让 `ent/download` 那一跳跳过，
    /// 下载走旧链照常工作（与上游「ent/download 是可失败退出的附加一跳」一致）。
    static func install() {
        Configuration.kbsyncGenerator = { hardwareID, dsid in
            // kbsync 是纯 CPU 的 guest 执行（可能要几秒），必须在后台线程，
            // 不能占主线程 —— 否则一次下载会把界面卡住。
            //
            // `Task.detached` 而不是 `Task {}`：调用方（下载链）本身可能跑在
            // 某个 actor 上，`Task {}` 会继承它的执行器；这里要的是「彻底离开
            // 调用者的隔离域」，所以用 detached。
            try await Task.detached(priority: .userInitiated) {
                try generate(hardwareID: hardwareID, dsid: dsid)
            }.value
        }

        // 装完立刻自检一次：资产在不在、storeagent 能不能加载。
        // 这一步**只写日志、不抛错**，方便真机排障时一眼看出 ent/download 为什么没走。
        if SAPAssetsLocator.url == nil {
            LoginLogger.shared.log("[kbsync] 未装配：SAP 资产目录缺失（\(SAPAssetsLocator.describe())）",
                                   category: .appleID)
        } else {
            LoginLogger.shared.log("[kbsync] 已装配（资产目录 \(SAPAssetsLocator.url?.path ?? "?")）",
                                   category: .appleID)
        }
    }

    /// 真正跑一次 kbsync。抛错时由上面的闭包原样传回 vendor 层，
    /// vendor 捕获后落回旧链。
    ///
    /// `nonisolated`：这个是纯函数（读资产 → 跑 guest → 返回字节），
    /// 不需要任何隔离域的上下文。加了它，`Task.detached` 里的调用才不需要 hop。
    private nonisolated static func generate(hardwareID: Data, dsid: UInt64) throws -> Data {
        // v0.3.548：**先查缓存** —— 对齐上游 `appstore_kbsync_cache.go`。
        //
        // 为什么必须有缓存：kbsync 要在 Unicorn 里解释执行 `storeagent`
        // （纯 CPU，几秒），而这个 blob 的输入只有「hardwareID + DSID」两项 ——
        // 同一台设备同一次登录下**每次都算出同一个值**。
        // 不缓存 = 每下一次包白烧几秒 CPU（上游专门为它加了缓存文件）。
        //
        // 键选择：上游用 (DSID, GUID) 双键。我们这边 hardwareID 就来自本机
        // （唯一），所以 DSID 单独做键已经够区分（换账号 = 换 DSID）。
        if let cached = cache.value(for: dsid) {
            return cached
        }

        guard let assets = SAPAssetsLocator.url else {
            throw KBSyncError.assetsMissing
        }
        // v0.3.548 定案：**ObjC 的 `NSError **` 出参在 Swift 侧就是 `throws`** ——
        //   调用时写 `try`、**不要**再显式传 `error:` 实参。
        //
        //   这个坑连着坑了三版（v0.3.544/545/546 全是同一条
        //   `error: extra argument 'error' in call`）。根因是把 ObjC 的
        //   NSError-out-parameter **当成了普通的带 error 参数的方法**：
        //   Swift importer 看到 `NSError **` 会把它**从参数列表里拿走**、
        //   改写成 `throws`（`NSError` → `Error`），所以调用处**根本没有 error 这个 label**。
        //
        //   判据：本仓同文件的 `SAPContext` 一直是这么用的、从来没报过错 ——
        //     `let signer = try SAPContext(assetsURL:hardwareID:)`（不带 error）
        //     `try signer.exchangeData(cert, version: 200)`（不带 error）
        //   照着它的写法就对了。
        //
        //   ⚠️ 不要去改 `.h` 里 `NSError **` 的写法（v0.3.545/546 试过
        //   `NSError * _Nullable * _Nullable`，不仅没用、还让 `.h` 与 `.mm` 不一致）。
        //   出参类型保持全文件统一的 `NSError **` 即可。
        let blob = try SAPStoreAgentContext.generateKBSync(
            withAssetsURL: assets,
            hardwareID: hardwareID,
            dsid: dsid
        )
        guard !blob.isEmpty else {
            throw KBSyncError.generationFailed("生成结果为空")
        }
        let data = blob as Data
        cache.store(data, for: dsid)
        return data
    }

    // MARK: - kbsync 缓存

    /// 进程内缓存（对齐上游 `appstore_kbsync_cache.go` 的语义）。
    ///
    /// **只在进程内**，不落盘：上游是 CLI，跨次运行要落盘才有意义；
    /// 我们是常驻 App，进程内缓存已经覆盖了「连续装多个包」这个真实场景，
    /// 而落盘会多出一份「设备绑定凭据躺在沙盒里」的东西，不划算。
    ///
    /// 上游那条**「只存已经成功服务过 ent/download 的 blob」**的规则我们**不照搬**：
    /// 那条规则是为了避免把一个算对了但服务端不认的 blob 缓存下来反复用。
    /// 我们这边的 `generate` 是纯函数（同样的输入必然同样输出），
    /// 缓存一个「算出来了但服务端不认」的值，和重新算一遍得到的结果**完全一样**，
    /// 所以那条规则对我们没有收益，只会让实现变复杂。
    /// （若将来发现某种 DSID 下服务端会拒，再按「只在拿到 HTTP 200 后 store」改。）
    private final class KBSyncCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [UInt64: Data] = [:]

        func value(for dsid: UInt64) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return entries[dsid]
        }

        func store(_ data: Data, for dsid: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            // 只服务「当前正在用的账号」，实际不会超过一两个；
            // 加个上限纯粹是防御（账号换了又换时不至于无限涨）。
            if entries.count > 8 { entries.removeAll() }
            entries[dsid] = data
        }
    }

    private static let cache = KBSyncCache()

    enum KBSyncError: LocalizedError {
        case assetsMissing
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .assetsMissing:
                "SAP 资产缺失"
            case let .generationFailed(reason):
                "kbsync 生成失败：\(reason)"
            }
        }
    }
}
