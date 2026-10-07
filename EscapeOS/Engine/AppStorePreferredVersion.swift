import Foundation

/// 下载链路「首轮版本号预解析」的宿主实现。
///
/// ## 为什么需要它
/// `ent/download` 是 AppleID 下载链的**首选**端点，但它硬性要求固定版本号
/// （`EntDownload.fetchProduct` 硬门 ③）。首轮 `externalVersionID` 为空时，旧链会掉进
/// `volumeStore`（≈1.5s）→ `redownload`（裸 HTTP 500，真机实测白等 8.9~11.4s）——
/// 见 `P4_全能签逆向/_impl/分析_前期慢时间线.md`。而同一个版本号一旦带上，
/// `ent/download` 一次就 200（两轮链路唯一差别就是版本号有无）。
///
/// 所以这里把「上次成功下载用过的 externalVersionId」提前交给 vendor 层
/// （`Configuration.preferredDownloadVersionProvider`），让**首轮**就能走
/// `ent/download`，跳过 `volumeStore + redownload` 那两步弯路。
///
/// ## 键格式（**必须与 `AppStoreLocalInstallService` 同口径**）
/// `AppStore.LastGoodVersion.<dsid>.<bundleId>` —— 与
/// `AppStoreLocalInstallService.cachedVersionID / rememberVersionID` 完全一致。
/// 那边是 private，这里只能同口径复读；**改动任一处的键格式都要同步改另一处**。
///
/// ## 保守性
/// 缓存没命中（该 App 首次成功下载之前）时返回 nil，vendor 层会原样落回旧的
/// `volumeStore → redownload` 链，行为与改动前完全一致 —— 不新增硬失败。
enum AppStorePreferredVersion {
    /// 在 App 启动时装配一次（见 `EscapeSpaceApp.init`），与 `KBSyncProvider.install()` 同处。
    static func install() {
        Configuration.preferredDownloadVersionProvider = { dsid, bundleID in
            Self.cachedLastGoodVersion(dsid: dsid, bundleID: bundleID)
        }
    }

    /// 读「上次成功用过的 externalVersionId」。纯本地 UserDefaults 读取，零网络。
    ///
    /// 只读缓存、**不**去查目录/爱思：目录那条链路（`candidateVersionIDs`）已经在
    /// `AppStoreLocalInstallService` 的补救状态机里，这里不重复、也不放大请求。
    nonisolated static func cachedLastGoodVersion(dsid: String, bundleID: String) -> String? {
        guard !dsid.isEmpty, !bundleID.isEmpty else { return nil }
        let key = "AppStore.LastGoodVersion.\(dsid).\(bundleID)"
        let value = UserDefaults.standard.string(forKey: key)
        return (value?.isEmpty == false) ? value : nil
    }
}
