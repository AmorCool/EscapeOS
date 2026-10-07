//
//  StoreCatalog.swift
//  ApplePackage
//
//  v0.3.329：目录版本解析（对齐 Asspp dev `65be5b04`）。
//
//  背景：2026-09 起 Apple 的 `volumeStoreDownloadProduct` 会对部分应用返回
//  **空包**（HTTP 200、failureType 空、customerMessage 空、songList 为空/缺失，
//  响应头里 `X-Apple-Request-Store-Front: <null>`）—— ipatool #549/#551/#543 都在报。
//  这种时候要换 `redownload` 端点重取，但**未固定版本号的 redownload 可能返回
//  tvOS 包**（Asspp 注释原话），所以必须先用 MDM lockup 接口把「当前版本」的
//  externalVersionId 解析出来，再带版本号去打 redownload。
//
import Foundation

enum StoreCatalog {

    private enum CatalogError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法从目录接口确定该应用的当前版本" }
    }

    /// 取某个应用在当前区域的「当前版本」externalVersionId（纯数字）
    ///
    /// v0.3.5xx：本文件此前**零日志**。补「入口 / 出口 / 耗时」，让「目录版本解析」
    /// 这一跳（原先是 `downloadInformation` 黑盒合计里的一部分）可单独归因。
    static func externalVersionID(appID: Int64, countryCode: String) async throws -> String {
        let started = Date()
        storeLog("[计时] StoreCatalog.externalVersionID 入口 appID=\(appID) cc=\(countryCode)")
        do {
            let version = try await resolveExternalVersionID(appID: appID, countryCode: countryCode)
            storeLog("[计时] StoreCatalog.externalVersionID 出口 版本=\(version)")
            storeLog("[计时] StoreCatalog.externalVersionID 耗时=\(elapsedMs(since: started))ms")
            return version
        } catch {
            storeLog("[计时] StoreCatalog.externalVersionID 出口 失败=\(error.localizedDescription)")
            storeLog("[计时] StoreCatalog.externalVersionID 耗时=\(elapsedMs(since: started))ms")
            throw error
        }
    }

    /// `[计时]` 日志用 —— 与锚点的毫秒差。
    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func resolveExternalVersionID(appID: Int64, countryCode: String) async throws -> String {
        var comps = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        comps.queryItems = [
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "id", value: String(appID)),
            URLQueryItem(name: "p", value: "mdm-lockup"),
            URLQueryItem(name: "caller", value: "MDM"),
            URLQueryItem(name: "platform", value: "enterprisestore"),
            URLQueryItem(name: "cc", value: countryCode.lowercased()),
            URLQueryItem(name: "l", value: "en"),
        ]
        guard let url = comps.url else { throw CatalogError.unavailable }

        var request = URLRequest(url: url)
        request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let netStarted = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        storeLog("[计时] StoreCatalog HTTP 耗时=\(elapsedMs(since: netStarted))ms 状态=\(statusCode) 字节=\(data.count)")
        guard statusCode == 200 else { throw CatalogError.unavailable }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let item = results[String(appID)] as? [String: Any],
              let offers = item["offers"] as? [[String: Any]]
        else { throw CatalogError.unavailable }

        for offer in offers {
            if let version = offer["version"] as? [String: Any],
               let external = version["externalId"].map({ "\($0)" }),
               isNumeric(external) {
                return external
            }
            if let buyParams = offer["buyParams"] as? String,
               let parsed = URLComponents(string: "?" + buyParams),
               let value = parsed.queryItems?.first(where: { $0.name == "appExtVrsId" })?.value,
               isNumeric(value) {
                return value
            }
        }
        throw CatalogError.unavailable
    }

    private static func isNumeric(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
