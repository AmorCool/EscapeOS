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
        guard let assets = SAPAssetsLocator.url else {
            throw KBSyncError.assetsMissing
        }
        var error: NSError?
        guard let blob = SAPStoreAgentContext.generateKBSync(
            withAssetsURL: assets,
            hardwareID: hardwareID,
            dsid: dsid,
            error: &error
        ) else {
            throw KBSyncError.generationFailed(error?.localizedDescription ?? "未知原因")
        }
        guard !blob.isEmpty else {
            throw KBSyncError.generationFailed("生成结果为空")
        }
        return blob as Data
    }

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
