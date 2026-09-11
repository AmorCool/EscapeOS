import Foundation

/// v0.3.301：本机设备身份 —— 供 App Store 下载请求使用。
///
/// **为什么需要**：Apple 的 `volumeStoreDownloadProduct` / `redownload` 请求体里只有
/// `guid` 与 `serialNumber` 两个字段能标识"请求来自哪台设备"（见 ApplePackage
/// `StoreDownloadEndpoint+Fetch.makeRequest`）。原实现里
/// `serialNumber` 写死 `"0"`、`guid` 是随机假 MAC —— Apple 只能把这请求当成一台
/// 匿名机器，于是它返回的 FairPlay `sinf` 用的是那台机器的证书加密，
/// 拿到本机交给 installd 必然解不开密文段（`ApplicationSINFCaptureFailed`）。
///
/// 改成传本机真实标识后，Apple 才有机会关联到**本机的 FairPlay 证书**，
/// 生成对本机有效的 sinf —— 这是"下载加密包也能直接安装"的唯一前提。
enum LocalDeviceIdentity {

    struct Snapshot {
        var serialNumber: String?
        var udid: String?
        var productType: String?
        /// lockdown `com.apple.mobile.iTunes` 域里的设备 FairPlay 证书（诊断用）
        var fairPlayCertificate: String?
        var fairPlayDeviceType: String?

        /// 下载请求的 `guid`：本机 UDID 去掉分隔符后的紧凑形式。
        /// UDID 是 Apple 侧认同的权威设备标识；12 位假 MAC 反而会被当成陌设备。
        var guid: String? {
            guard let raw = udid?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            let compact = raw
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
            return compact.isEmpty ? nil : compact.uppercased()
        }

        /// 是否拿到了可用的本机身份（序列号是 Apple 关联 FairPlay 证书的关键）
        var isUsable: Bool {
            !(serialNumber ?? "").isEmpty
        }

        var summary: String {
            let sn = serialNumber ?? "-"
            let guid = guid.map { String($0.prefix(12)) + "…" } ?? "-"
            return "序列号 \(sn) · guid \(guid) · \(productType ?? "-")"
        }
    }

    /// 读取本机身份（走 RSD 隧道 lockdown）。
    ///
    /// 不抛错：任何一步失败都返回已拿到的部分，让下载链路继续（并靠日志暴露问题）。
    static func load() -> Snapshot {
        var s = Snapshot()
        if let root = try? DeviceInfoService.lockdownFullDict() {
            s.serialNumber = root["SerialNumber"] as? String
            s.udid = root["UniqueDeviceIdentifier"] as? String
            s.productType = root["ProductType"] as? String
        }
        if let itunes = try? DeviceInfoService.lockdownDomainDict("com.apple.mobile.iTunes") {
            s.fairPlayCertificate = itunes["FairPlayCertificate"] as? String
            if let n = itunes["FairPlayDeviceType"] as? NSNumber {
                s.fairPlayDeviceType = n.stringValue
            } else {
                s.fairPlayDeviceType = itunes["FairPlayDeviceType"] as? String
            }
        }
        return s
    }

    /// 读取本机身份并写入 ApplePackage 的全局配置（下载 payload 直接读这两个值）。
    ///
    /// ⚠️ **只写 `deviceSerialNumber`，绝不改写 `deviceIdentifier`**（v0.3.307 修正）。
    ///
    /// 原因（真机报错 `MZFinance.NoAccount_message` 的根因）：登录与下载**必须用同一个 guid**。
    /// 登录与下载共用 `AppStoreDownloadStore.init` 里 `bootstrapDeviceIdentifier`
    /// 生成的持久化随机标识，Apple 的会话（passwordToken / dsid / cookie）
    /// 就绑在这个 guid 上；而 v0.3.301 曾在这里把 `Configuration.deviceIdentifier`
    /// 覆盖成 UDID，于是下载请求带着**另一个 guid** 出去 —— Apple 认不出这是哪个会话，
    /// 直接回 `MZFinance.NoAccount_message`（表现为「能登录但下不了」）。
    /// 序列号照旧传本机真值：它才是 Apple 关联本机 FairPlay 证书、生成可用 sinf 的依据。
    @discardableResult
    static func apply() -> Snapshot {
        let s = load()
        if let sn = s.serialNumber, !sn.isEmpty {
            Configuration.deviceSerialNumber = sn
        }
        return s
    }

    /// 下载请求实际会用的 guid（= 登录时用的那个持久化标识），用于日志对照
    static var downloadGUID: String { Configuration.deviceIdentifier }
}
