//
//  Bag.swift
//  ApplePackage
//
//  Created on 2026/2/20. (Ported from ApplePackage 1.2.7 to the shim environment)
//
// 通过 init.itunes.apple.com/bag.xml 拿动态 auth 端点 —— ApplePackage 1.2.7 主线
// 做法，避免硬编码 native/fast URL（老 URL 会被 Apple 边缘以 301 拒绝到 HTML 页）。
// 这是 PR #84 (2026-06-12) 的核心修复之一。
//

import Foundation

public enum Bag {
    public struct BagOutput {
        public var authEndpoint: URL
    }

    /// 兜底端点 —— Bag.fetchBag() 任何一步失败都回落到这里。
    /// 路径**带尾斜杠**（无尾斜杠的变体被 Apple 边缘 301 到 HTML 页）。
    private static let defaultAuthEndpoint = "https://auth.itunes.apple.com/auth/v1/native/fast/"

    public static func fetchBag() async throws -> BagOutput {
        let deviceIdentifier = Configuration.deviceIdentifier

        let client = Configuration.makeHTTPClient(
            redirectConfiguration: .follow(max: 8, allowCycles: false)
        )
        defer { _ = client.shutdown() }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "init.itunes.apple.com"
        comps.path = "/bag.xml"
        comps.queryItems = [URLQueryItem(name: "guid", value: deviceIdentifier)]
        guard let url = comps.url else {
            return BagOutput(authEndpoint: URL(string: defaultAuthEndpoint)!)
        }

        let headers: [(String, String)] = [
            ("User-Agent", Configuration.userAgent),
            ("Accept", "application/xml"),
        ]

        let request = try HTTPClient.Request(
            url: url.absoluteString,
            method: .GET,
            headers: HTTPHeaders(headers),
            body: .none
        )

        let response = try await client.execute(request: request).get()
        print(
            "[EscapeOS][Bag] init.itunes.apple.com/bag.xml status=\(response.status.code) bytes=\(response.body?.readableBytes ?? 0)"
        )

        guard var body = response.body,
              let data = body.readData(length: body.readableBytes)
        else {
            print("[EscapeOS][Bag] 空响应体，回退 default auth endpoint")
            return BagOutput(authEndpoint: URL(string: defaultAuthEndpoint)!)
        }

        let plistData = extractPlistData(from: data)

        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            print("[EscapeOS][Bag] plist 解析失败，回退 default auth endpoint")
            return BagOutput(authEndpoint: URL(string: defaultAuthEndpoint)!)
        }

        // authenticateAccount 现在在 plist 根；老 bag 还会把它放在 urlBag dict 里 ——
        // 1.2.7 主线 root 优先，urlBag 兜底。
        let urlBag = plist["urlBag"] as? [String: Any] ?? [:]
        let authURLString = (plist["authenticateAccount"] as? String)
            ?? (urlBag["authenticateAccount"] as? String)

        guard let authURLString,
              let authURL = normalizedAuthEndpoint(from: authURLString)
        else {
            print("[EscapeOS][Bag] 找不到 authenticateAccount，回退 default auth endpoint")
            return BagOutput(authEndpoint: URL(string: defaultAuthEndpoint)!)
        }

        print("[EscapeOS][Bag] 解析到 auth endpoint: \(authURL.absoluteString)")
        return BagOutput(authEndpoint: authURL)
    }

    /// Apple bag 给的 native auth 端点常缺 `/fast/` 子路径且无尾斜杠。
    /// 没有 `/fast/` 的变体被 Apple 边缘 301 到 HTML 页（v0.2.151 真机 404 实锤）。
    /// 这里强制规范成 `auth.itunes.apple.com/.../fast/` 格式。
    ///
    /// v0.2.156 新增 legacy 回退：2026-08-31 真机 + curl 实证（5 组 guid/UA 对照），
    /// Configurator UA 下 bag.xml 的 `authenticateAccount` 返回 legacy
    /// `buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate` ——
    /// 该端点 2026 年起要求 SAP 签名（`X-Apple-ActionSignature`，ipatool 实证），
    /// shim 环境无法签名，跟随其 302 到 pod 后必挂「failed to retrieve
    /// redirect location」（v0.2.155 真机实锤）。凡 legacy 端点一律回退
    /// `defaultAuthEndpoint`（native/fast/，与 AssppWeb `defaultAuthURL` 兜底思路一致）。
    private static func normalizedAuthEndpoint(from urlString: String) -> URL? {
        guard var comps = URLComponents(string: urlString) else { return nil }
        if comps.host == "buy.itunes.apple.com",
           comps.path.hasSuffix("/wa/authenticate") {
            print("[EscapeOS][Bag] bag.xml 给出 legacy wa/authenticate 端点（需 SAP 签名，无法使用），回退 default native/fast/")
            return URL(string: defaultAuthEndpoint)
        }
        if comps.host == "auth.itunes.apple.com" {
            var path = comps.path
            while path.hasSuffix("/") {
                path.removeLast()
            }
            if !path.hasSuffix("/fast") {
                path += "/fast"
            }
            comps.path = path + "/"
        }
        return comps.url
    }

    /// Bag XML 响应把 plist 包在 `<Document><Protocol><plist>...</plist></Protocol></Document>` 里。
    /// PropertyListSerialization 处理不了外层 XML，只能手动抽出 `<plist>...</plist>` 段。
    /// 如果 body 已经是裸 plist，原样返回。
    private static func extractPlistData(from data: Data) -> Data {
        guard let xmlString = String(data: data, encoding: .utf8),
              let startRange = xmlString.range(of: "<plist"),
              let endRange = xmlString.range(of: "</plist>")
        else {
            return data
        }
        return Data(xmlString[startRange.lowerBound ..< endRange.upperBound].utf8)
    }
}
