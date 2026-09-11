import Foundation
import Security

/// v0.3.298：爱思手机端（AsTools.app）接口客户端 —— 逆向成果的落地实现
///
/// 【完整证据链】
/// - 协议与参数：`217.ipa` 内 `HotJs/*/main.jsbundle`（React Native 明文 JS）
///   · 请求签名：`buildJson(params)` = `NativeModules.Crypto.rsa({...params, sappid: 2891})`
///   · 发送格式：`POST <host><path>`，body = `("?json=" + 密文).substring(1)` → 即 `json=<密文>`
///   · 加密实现在原生模块 `Crypto`：`rsa:isUpdate:isBase64:resolver:rejecter:` /
///     `threeDES:key:resolver:rejecter:`
/// - 密钥素材：`com.ownbook.notes.app`（解密版，cryptid=0）的 `Runner` 主二进制
///   · RSA 公钥（1024-bit）：见下方 `rsaPublicKeyPKCS1Base64`
///   · 3DES 密钥规则：`2014aisi1234567890` + 业务后缀
///     （本业务后缀 `mobileclient29` → `2014aisi1234567890mobileclient29`，ECB）
///   · appId = 2891，appKey = `961eb17e9820405783050223fdf94d53`
/// - 关键词表探测：裸请求一律返回 `{"appstatus":0,"appmsg":"游戏未开放，暂无信息"}`；
///   走签名后 `getSpecialList.xhtml` 返回真实 JSON（专题 id 3283「掌上自习室」等），
///   证明公钥、填充方式与报文形态均正确。
///
/// 安装通道（与爱思手机端同一条系统调用）：
///   `itms-services://?action=download-manifest&url=<plist>`，plist 字段来自 `appinfo.xhtml`
///   的 `plist` / `plist_s`（`onlyshare == 1` 用 plist，否则 plist_s），IPA 托管在 dl.i4.cn。
enum I4StoreClient {

    // MARK: - 常量（逆向取得）

    /// RSA 公钥（PKCS#1 / RSAPublicKey，1024-bit）
    static let rsaPublicKeyPKCS1Base64 =
        "MIGJAoGBAKm1/7htopbrloLzGCrp8z6edQtljvl+7PkZAKblilIFtClihz52sERfEy5xnFHn0S7O4gSWCIpFgrZ5N3mVwwpsTpm1aQZ3fqC7yQ+iQxee6y/eceB7vAmc9JPVXATWpKQGf1IDOljwIbUzXa5B035Y1Xs3UO4JxrOgEQ38Pp7fAgMBAAE="
    /// 3DES 密钥前缀（业务后缀按 App 区分：本业务 mobileclient29 / 支付侧 321payplatform）
    static let desKeyPrefix = "2014aisi1234567890"
    static let desKeyApp = "2014aisi1234567890mobileclient29"
    /// 客户端标识
    static let sappid = 2891
    static let appKey = "961eb17e9820405783050223fdf94d53"
    static let clientVersion = "2.1.7"

    /// 服务端主机（逆向自 JS 的域名常量表）
    enum Host {
        static let list = "https://list-app-m.i4.cn/"
        static let search = "https://search-app-m.i4.cn/"
        static let config = "https://pub-conf-m.i4.cn/"
        static let user = "https://usercenter.i4.cn/"
        static let ring = "https://list-ring-m.i4.cn/"
        static let paper = "https://list-paper-m.i4.cn/"
        static let emoji = "https://list-emoji-m.i4.cn/"
    }

    /// 接口路径（逆向自 JS 的 `g.XXX_Path` 常量表）
    enum Path {
        static let appList = "getAppList.xhtml"
        static let appInfo = "appinfo.xhtml"
        static let appTypeList = "getAppTypeList.xhtml"
        static let specialList = "getSpecialList.xhtml"
        static let updateQuery = "updateAppQuery.xhtml"
        static let fuzzySearch = "querykeywordsbyinput.xhtml"
        static let hotSearch = "getHotSearchList.xhtml"
        static let selfUpdate = "getversioninfo.xhtml"
        static let deviceInfo = "getAppleDeviceInfo.xhtml"
    }

    /// 榜单（remd 值逆向自 JS 的 tab 定义）
    enum Rank: Int, CaseIterable, Identifiable {
        case savingHot = 30501      // 省钱安装 · 最热
        case savingExpensive = 30502 // 省钱安装 · 最贵
        case savingNew = 30503       // 省钱安装 · 最新
        case freeHot = 30101         // 限时免费 · 最热
        case freeExpensive = 30102
        case freeNew = 30103
        case mustHave = 302          // 装机必备

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .savingHot: return "省钱安装 · 最热"
            case .savingExpensive: return "省钱安装 · 最贵"
            case .savingNew: return "省钱安装 · 最新"
            case .freeHot: return "限时免费 · 最热"
            case .freeExpensive: return "限时免费 · 最贵"
            case .freeNew: return "限时免费 · 最新"
            case .mustHave: return "装机必备"
            }
        }
    }

    // MARK: - 加密

    enum CryptoError: Error, LocalizedError {
        case badPublicKey
        case encryptFailed(String)
        case tooLong

        var errorDescription: String? {
            switch self {
            case .badPublicKey: return "公钥无效"
            case .encryptFailed(let m): return "加密失败：\(m)"
            case .tooLong: return "数据过长"
            }
        }
    }

    private static func publicKey() throws -> SecKey {
        guard let data = Data(base64Encoded: rsaPublicKeyPKCS1Base64) else { throw CryptoError.badPublicKey }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024,
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attrs as CFDictionary, &err) else {
            throw CryptoError.badPublicKey
        }
        return key
    }

    /// RSA PKCS#1 v1.5 分段加密 → base64
    ///
    /// 1024-bit 单段上限 = 128 - 11 = 117 字节；超长时按 117 字节切分，
    /// 每段密文（128 字节）依次拼接后整体 base64（与爱思 `Crypto.rsa` 同为分段实现，
    /// 因为其 commonParams 序列化后必然超过单段上限）。
    static func rsaEncrypt(_ plain: Data) throws -> String {
        let key = try publicKey()
        let blockSize = SecKeyGetBlockSize(key)          // 128
        let maxChunk = blockSize - 11                     // 117
        var cipher = Data()
        var offset = 0
        while offset < plain.count {
            let end = min(offset + maxChunk, plain.count)
            let chunk = plain.subdata(in: offset..<end)
            var err: Unmanaged<CFError>?
            guard let out = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, chunk as CFData, &err) else {
                let msg = (err?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
                throw CryptoError.encryptFailed(msg)
            }
            cipher.append(out as Data)
            offset = end
        }
        return cipher.base64EncodedString()
    }

    // MARK: - 请求

    /// 构造请求体（`json=<密文>`）
    static func makeBody(_ params: [String: Any]) throws -> String {
        var payload = params
        payload["sappid"] = sappid
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return "json=" + (try rsaEncrypt(data))
    }

    /// 调用一个接口，返回原始响应体
    static func callRaw(host: String, path: String, params: [String: Any],
                        timeout: TimeInterval = 20) async throws -> Data {
        guard let url = URL(string: host + path) else { throw AppStoreError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("AsTools/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        req.httpBody = (try makeBody(params)).data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppStoreError.http(http.statusCode)
        }
        return data
    }

    /// 调用接口并解码 JSON 字典
    static func call(host: String, path: String, params: [String: Any]) async throws -> [String: Any] {
        let data = try await callRaw(host: host, path: path, params: params)
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    // MARK: - 业务接口（按已验证的调用形态封装）

    /// 专题列表（已实测：返回 `{"list":[{id,name,introduce,icon,scount}, ...]}`）
    static func specialList(pageSize: Int = 20, pageno: Int = 1) async throws -> [[String: Any]] {
        let obj = try await call(host: Host.list, path: Path.specialList,
                                 params: ["pageSize": "\(pageSize)", "pageno": pageno])
        return (obj["list"] as? [[String: Any]]) ?? []
    }

    /// 分类列表
    static func appTypeList(pageno: Int = 1, pageSize: Int = 20) async throws -> [[String: Any]] {
        let obj = try await call(host: Host.list, path: Path.appTypeList,
                                 params: ["pageSize": "\(pageSize)", "pageno": pageno])
        return (obj["list"] as? [[String: Any]]) ?? []
    }

    /// 应用列表（按榜单 remd + 排序）
    /// 返回结构：`{"app":[...], "adli":[...], "spappli":[...]}`
    static func appList(rank: Rank, sort: Int = 1, pageno: Int = 1, pageSize: Int = 20) async throws -> [[String: Any]] {
        let obj = try await call(host: Host.list, path: Path.appList, params: [
            "pageSize": "\(pageSize)",
            "pageno": pageno,
            "remd": rank.rawValue,
            "sort": sort,
        ])
        return (obj["app"] as? [[String: Any]]) ?? []
    }

    /// 应用详情（含 `plist` / `plist_s` / `path` / `size` / `md5` / `version` 等）
    static func appInfo(appid: String) async throws -> [String: Any] {
        try await call(host: Host.list, path: Path.appInfo, params: ["appid": appid])
    }

    /// 从详情字典解析出可用于 `itms-services` 的 manifest plist 地址
    /// 规则（逆向自 JS）：`onlyshare == 1` 用 `plist`，否则用 `plist_s`
    static func manifestURL(from appInfo: [String: Any]) -> String? {
        let onlyShare = (appInfo["onlyshare"] as? NSNumber)?.intValue ?? 0
        let plist = appInfo["plist"] as? String
        let plistS = appInfo["plist_s"] as? String
        var url = (onlyShare == 1 ? plist : plistS) ?? plistS ?? plist
        guard var u = url, !u.isEmpty else { return nil }
        if u.hasPrefix("//") { u = "https:" + u }
        return u
    }

    /// 搜索（走 search 域）
    static func search(keyword: String, pageno: Int = 1, pageSize: Int = 20) async throws -> [[String: Any]] {
        let obj = try await call(host: Host.search, path: Path.fuzzySearch, params: [
            "keyword": keyword,
            "pageSize": "\(pageSize)",
            "pageno": pageno,
        ])
        if let list = obj["list"] as? [[String: Any]] { return list }
        if let app = obj["app"] as? [[String: Any]] { return app }
        return []
    }
}
