import Foundation

//
//  SupervisionService.swift
//  EscapeOS
//
//  v0.3.249：监督（Supervision）身份与通道.
//
//  MCInstall 的 Escalate 需要监督身份：自签证书注册进设备 CloudConfiguration 的
//  SupervisorHostCertificates，设备下发 Challenge，再用 PKCS7 附签回传
//  （对齐 pymobiledevice3 MobileConfigService.escalate / supervise）。
//
//  分工：
//  - 本文件：身份生成/持久化（libcrypto，ZSign 同源）+ PKCS7 签名回调注册
//  - WirelessLockdownService：隧道、MCInstall 请求、SetCloudConfiguration / Escalate 编排
//
//  ⚠️ 开启会把设备置于受监督状态（设置里显示「此 iPhone 由 xx 组织监管」），
//    目前 MCInstall 没有公开的撤销接口，属于不可自动回退的设备状态变化。
//

enum SupervisionService {

    static let orgKey = "supervisionOrgName"
    static let certPemKey = "supervisionCertPem"
    static let keyPemKey = "supervisionKeyPem"
    static let certDerKey = "supervisionCertDerB64"
    static let enabledKey = "supervisionEnabled"

    /// 监督通道开关（只决定「射频开关要不要先 Escalate」，不代表设备是否已被监督）
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func setEnabledFlag(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    static func organization() -> String {
        UserDefaults.standard.string(forKey: orgKey) ?? "EscapeOS"
    }

    /// 身份是否齐全（证书 PEM / 私钥 PEM / 证书 DER 三者都在）
    static func hasIdentity() -> Bool {
        let d = UserDefaults.standard
        return !(d.string(forKey: certPemKey) ?? "").isEmpty
            && !(d.string(forKey: keyPemKey) ?? "").isEmpty
            && !(d.string(forKey: certDerKey) ?? "").isEmpty
    }

    /// 证书 DER（Escalate / SupervisorHostCertificates 用）
    static func certificateDER() -> [UInt8]? {
        guard let b64 = UserDefaults.standard.string(forKey: certDerKey),
              let data = Data(base64Encoded: b64) else { return nil }
        return [UInt8](data)
    }

    /// 生成（或复用）监督身份。身份跨会话保持不变——换身份等于设备侧监督失效。
    static func ensureIdentity(organization: String) throws {
        if hasIdentity() { return }

        var certPem: UnsafeMutablePointer<CChar>?
        var keyPem: UnsafeMutablePointer<CChar>?
        var certDer: UnsafeMutablePointer<UInt8>?
        var certPemLen: Int32 = 0
        var keyPemLen: Int32 = 0
        var certDerLen: Int32 = 0

        let rc = organization.withCString { cn in
            zsign_gen_supervision_identity(cn, &certPem, &certPemLen,
                                           &keyPem, &keyPemLen,
                                           &certDer, &certDerLen)
        }
        defer {
            if let certPem { free(certPem) }
            if let keyPem { free(keyPem) }
            if let certDer { free(certDer) }
        }
        guard rc == 0, let certPem, let keyPem, let certDer,
              certPemLen > 0, keyPemLen > 0, certDerLen > 0 else {
            throw NSError(domain: "SupervisionService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "生成监督身份失败（rc=\(rc)）"])
        }

        let certPEM = String(cString: certPem)
        let keyPEM = String(cString: keyPem)
        let derData = Data(bytes: certDer, count: Int(certDerLen))

        let d = UserDefaults.standard
        d.set(organization, forKey: orgKey)
        d.set(certPEM, forKey: certPemKey)
        d.set(keyPEM, forKey: keyPemKey)
        d.set(derData.base64EncodedString(), forKey: certDerKey)
    }

    /// 注册 PKCS7 签名回调进 Rust（幂等）。App 启动后第一次用到监督通道前调用即可。
    static func registerSigner() {
        mcinstall_set_pkcs7_sign_fn(supervision_pkcs7_cfn)
    }
}

/// 注册进 Rust 的 PKCS7 附签回调（C 函数指针）。
/// 入参 data 为设备下发的 Challenge；出参 DER 由 malloc 分配、Rust 侧 libc::free 释放
/// （Darwin 上两者是同一套分配器）。
let supervision_pkcs7_cfn: @convention(c) (
    UnsafePointer<UInt8>?, Int32,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    UnsafeMutablePointer<Int32>?
) -> Int32 = { data, dataLen, derOut, derLen in
    guard let data, let derOut, let derLen, dataLen > 0 else { return -1 }
    let d = UserDefaults.standard
    guard let certPem = d.string(forKey: SupervisionService.certPemKey),
          let keyPem = d.string(forKey: SupervisionService.keyPemKey) else { return -2 }

    var out: UnsafeMutablePointer<UInt8>?
    var outLen: Int32 = 0
    let certLen = Int32(certPem.utf8.count)
    let keyLen = Int32(keyPem.utf8.count)
    let rc = certPem.withCString { c in
        keyPem.withCString { k in
            zsign_pkcs7_sign_data(c, certLen, k, keyLen, data, dataLen, &out, &outLen)
        }
    }
    guard rc == 0, let out, outLen > 0 else {
        if let out { free(out) }
        return -3
    }
    derOut.pointee = out
    derLen.pointee = outLen
    return 0
}
