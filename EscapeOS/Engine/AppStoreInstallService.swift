import Foundation
import UIKit

/// v0.3.297：AppStore 商店 —— 安装服务（全新独立实现，不复用 IPAInstallService / ApplePackage）
///
/// 职责：把「某个 App」解析成一个 manifest plist 地址，然后交给 iOS 系统的
/// itms-services 通道安装（与爱思助手手机端完全同一条系统调用）。
///
/// 解析顺序：
///   1) 源的 `plistURLTemplate`（模板直接拼出 plist 地址）
///   2) 源的 `infoURLTemplate`（请求接口，按 `plistFieldPath` 从 JSON 取 plist 地址）
/// 安装动作：`itms-services://?action=download-manifest&url=<plist>`
enum AppStoreInstallService {

    enum InstallError: Error, LocalizedError {
        case noSource
        case badTemplate
        case requestFailed(String)
        case plistNotFound
        case cannotOpen

        var errorDescription: String? {
            switch self {
            case .noSource: return "没有可用的分发源，请先在「分发源管理」里添加并启用"
            case .badTemplate: return "源模板拼出的地址无效"
            case .requestFailed(let m): return "源接口请求失败：\(m)"
            case .plistNotFound: return "源返回里没有找到 plist 地址"
            case .cannotOpen: return "无法打开安装链接"
            }
        }
    }

    // MARK: - 解析 plist 地址

    /// 从源解析出该 App 的 manifest plist 地址
    static func resolvePlistURL(item: AppStoreItem, source: AppStoreSource) async throws -> String {
        // 1) 模板直出
        let tpl = source.plistURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tpl.isEmpty {
            let filled = source.fill(tpl, item: item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filled.isEmpty else { throw InstallError.badTemplate }
            return filled
        }
        // 2) 请求接口再取字段
        let infoTpl = source.infoURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !infoTpl.isEmpty else { throw InstallError.noSource }
        let urlStr = source.fill(infoTpl, item: item)
        guard let url = URL(string: urlStr) else { throw InstallError.badTemplate }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let hdrs = parseHeaders(source.extraHeaders) {
            for (k, v) in hdrs { req.setValue(v, forHTTPHeaderField: k) }
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw InstallError.requestFailed(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.requestFailed("HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw InstallError.requestFailed("返回不是 JSON")
        }
        let path = source.plistFieldPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let value = value(at: path, in: obj) else {
            throw InstallError.plistNotFound
        }
        var plist = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plist.isEmpty else { throw InstallError.plistNotFound }
        // 协议相对地址补 https
        if plist.hasPrefix("//") { plist = "https:" + plist }
        return plist
    }

    // MARK: - 安装

    /// 用某个源安装该 App（交给系统 OTA）
    @discardableResult
    static func install(item: AppStoreItem, source: AppStoreSource,
                        onLog: ((String) -> Void)? = nil) async throws -> String {
        onLog?("[源] 使用「\(source.name)」解析 plist…")
        let plist = try await resolvePlistURL(item: item, source: source)
        onLog?("[源] plist = \(plist)")
        let ok = AppStoreInstaller.installViaOTA(manifestURL: plist)
        guard ok else { throw InstallError.cannotOpen }
        onLog?("[安装] 已交给系统 itms-services 安装")
        return plist
    }

    /// 依次尝试所有启用的源，直到有一个能解析成功
    @discardableResult
    static func installUsingAnySource(item: AppStoreItem,
                                      onLog: ((String) -> Void)? = nil) async throws -> (plist: String, source: AppStoreSource) {
        let list = AppStoreSourceStore.shared.enabledSources
        guard !list.isEmpty else { throw InstallError.noSource }
        var lastError: Error = InstallError.noSource
        for s in list {
            do {
                onLog?("[源] 尝试「\(s.name)」…")
                let plist = try await resolvePlistURL(item: item, source: s)
                onLog?("[源] 命中：\(plist)")
                guard AppStoreInstaller.installViaOTA(manifestURL: plist) else {
                    throw InstallError.cannotOpen
                }
                return (plist, s)
            } catch {
                lastError = error
                onLog?("[源] 「\(s.name)」失败：\(error.localizedDescription)")
            }
        }
        throw lastError
    }

    // MARK: - 工具

    /// `a.b.c` 取值
    private static func value(at path: String, in obj: Any) -> String? {
        var cur: Any = obj
        for seg in path.split(separator: ".") {
            let key = String(seg)
            if let dict = cur as? [String: Any], let next = dict[key] {
                cur = next
            } else if let arr = cur as? [Any], let idx = Int(key), idx < arr.count {
                cur = arr[idx]
            } else {
                return nil
            }
        }
        if let s = cur as? String { return s }
        if let n = cur as? NSNumber { return n.stringValue }
        return nil
    }

    /// 解析形如 `{"X-Token":"abc"}` 的请求头
    private static func parseHeaders(_ raw: String) -> [String: String]? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let d = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = (v as? String) ?? "\(v)" }
        return out.isEmpty ? nil : out
    }
}
