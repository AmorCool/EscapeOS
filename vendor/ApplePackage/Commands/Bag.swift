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
        // v0.4.0：SAP 签名端点（bag.xml 的 sign-sap-* 键，ipatool PR #525 同款）。
        // bag 解析失败 / 老缓存 / 兜底端点场景下为 nil → 认证请求退回未签名行为。
        public var sapSetupURL: URL?
        public var sapCertificateURL: URL?
        public var sapVersion: UInt32?
    }

    /// 兜底端点 —— Bag.fetchBag() 网络失败 / 解析失败时最后回落。
    /// v0.3.1：由 native/fast 改为 legacy wa/authenticate —— upstream ipatool
    /// PR #525 的 validateAuthenticationEndpoint 只认这个端点（SAP 签名为它设计）；
    /// native/fast 已被 2026-08-31 真机证实是死路（无 SAP 认证 404×2 + 301 裸重定向）。
    /// 注意：走到兜底时 bag 的 sign-sap-* 也不可用 → 请求会未签名发出（必被拒），
    /// 仅保证行为可预期、日志可诊断，不再伪装成「能用的路径」。
    private static let defaultAuthEndpoint = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"

    // v0.2.159（审计 Q9）：单会话内 auth 端点基本不变，缓存上一次成功解析的端点，
    // 避免每次 `Authenticator.authenticate` 都重新拉 bag.xml（既省耗时也减少 Apple 边缘请求次数）。
    // 以 deviceIdentifier 为键：Anisette 重置导致标识变化时会自动失效并重拉。
    // v0.4.0：缓存升级为完整 BagOutput（连同 sign-sap-* 三元组一起缓存）。
    private static var cachedOutput: BagOutput?
    private static var cachedDeviceIdentifier: String = ""

    public static func fetchBag() async throws -> BagOutput {
        let deviceIdentifier = Configuration.deviceIdentifier

        // 会话内已成功解析过、且设备标识未变 → 直接命中缓存，跳过 bag.xml 网络请求（审计 Q9）。
        // 既能减少每次认证的耗时，也降低对 Apple 边缘的请求频率（避免触发限流）。
        if cachedDeviceIdentifier == deviceIdentifier, let cached = cachedOutput {
            print("[EscapeOS][Bag] 命中会话缓存 auth endpoint: \(cached.authEndpoint.absoluteString)")
            LoginLogger.shared.log("[Bag] 命中会话缓存 auth endpoint: \(cached.authEndpoint.absoluteString)")
            return cached
        }

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
            // v0.4.1（真机实锤 + 实测对照）：bag.xml **只对 Configurator UA 返回完整键**——
            // iTunes UA 拿到的 103KB 响应里连 authenticateAccount / sign-sap-* 都没有，
            // 无 UA 同样拿不到；只有 Configurator UA（upstream pkg/http AddHeaderTransport
            // 注入的 DefaultUserAgent）才返回完整 urlBag（authenticateAccount + sign-sap-*）。
            // 这是 v0.4.0 真机登录 404×2 + 301 的根因：bag 缺键 → 走 default 端点 + 无签名。
            ("User-Agent", Configuration.bagUserAgent),
            ("Accept", "application/xml"),
        ]

        let request = HTTPClient.Request(
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
            return fallbackEndpoint()
        }

        let plistData = extractPlistData(from: data)

        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            print("[EscapeOS][Bag] plist 解析失败，回退 default auth endpoint")
            return fallbackEndpoint()
        }

        // authenticateAccount 现在在 plist 根；老 bag 还会把它放在 urlBag dict 里 ——
        // 1.2.7 主线 root 优先，urlBag 兜底。
        let urlBag = plist["urlBag"] as? [String: Any] ?? [:]
        let authURLString = (plist["authenticateAccount"] as? String)
            ?? (urlBag["authenticateAccount"] as? String)

        // v0.4.0：SAP 签名端点三元组（root 优先，urlBag 兜底；与 ipatool
        // appstore_bag.go 的 urlBag plist 键一一对应）。缺失 → sapOutput 为 nil，
        // 认证请求退回未签名行为（Apple 现行策略下会 403，但保留旧行为不崩溃）。
        let sapSetupString = (plist["sign-sap-setup"] as? String)
            ?? (urlBag["sign-sap-setup"] as? String)
        let sapCertString = (plist["sign-sap-setup-cert"] as? String)
            ?? (urlBag["sign-sap-setup-cert"] as? String)
        let sapVersionString = (plist["sign-sap-version"] as? String)
            ?? (urlBag["sign-sap-version"] as? String)
        let sapVersion = sapVersionString.flatMap { UInt32($0) }

        guard let authURLString,
              let authURL = normalizedAuthEndpoint(from: authURLString)
        else {
            print("[EscapeOS][Bag] 找不到 authenticateAccount，回退 default auth endpoint")
            LoginLogger.shared.log("[Bag] bag.xml 缺 authenticateAccount，回退 default 端点（无 SAP 键）")
            return fallbackEndpoint()
        }

        var output = BagOutput(authEndpoint: authURL)
        if let sapSetupString, let sapCertString,
           let setupURL = URL(string: sapSetupString), let certURL = URL(string: sapCertString) {
            output.sapSetupURL = setupURL
            output.sapCertificateURL = certURL
            output.sapVersion = sapVersion
            print("[EscapeOS][Bag] 解析到 SAP 端点: setup=\(sapSetupString) version=\(sapVersionString ?? "200(缺省)")")
            LoginLogger.shared.log("[Bag] 解析到 SAP 端点: setup=\(sapSetupString) version=\(sapVersionString ?? "200(缺省)")")
        } else {
            print("[EscapeOS][Bag] bag.xml 未提供完整 sign-sap-setup/setup-cert 端点，SAP 签名不可用")
            LoginLogger.shared.log("[Bag] bag.xml 未提供完整 sign-sap-setup/setup-cert 端点，SAP 签名不可用")
        }

        // 成功解析则更新会话缓存（下次直接命中，跳过网络）。
        cachedDeviceIdentifier = deviceIdentifier
        cachedOutput = output
        print("[EscapeOS][Bag] 解析到 auth endpoint: \(output.authEndpoint.absoluteString)")
        LoginLogger.shared.log("[Bag] 解析到 auth endpoint: \(output.authEndpoint.absoluteString)")
        return output
    }

    /// 兜底端点解析（bag 网络/解析失败时调用）：优先复用会话内已成功解析的输出
    /// （审计 Q9 缓存，含 sign-sap-* 三元组）；没有缓存才回落硬编码 defaultAuthEndpoint。
    private static func fallbackEndpoint() -> BagOutput {
        if cachedDeviceIdentifier == Configuration.deviceIdentifier,
           let cached = cachedOutput {
            print("[EscapeOS][Bag] 网络/解析失败，复用会话缓存 auth endpoint")
            return cached
        }
        print("[EscapeOS][Bag] 无会话缓存，回落 defaultAuthEndpoint（legacy wa/authenticate，无 SAP 键）")
        return BagOutput(authEndpoint: URL(string: defaultAuthEndpoint)!)
    }

    /// v0.3.1（真机实锤 + upstream 对照）撤销 v0.2.156 的 legacy 强制回退：
    /// 当时前提是「legacy wa/authenticate 需要 SAP 签名而 shim 无法签名」——
    /// v0.3.0 SAP 桥落地后前提已反转：**SAP 签名正是为 legacy 端点准备的**
    /// （upstream ipatool PR #525 的 validateAuthenticationEndpoint 只认
    /// `buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate`）。
    /// native/fast 反而被 2026-08-31 真机证实是死路：无 SAP 认证 404×2 + 301 裸重定向。
    /// 现在信任 bag 给的端点，仅做 https 基本校验；
    /// auth.itunes.apple.com 域名保留 /fast 规范化（Apple 给的 native 端点常缺该子路径，
    /// v0.2.151 真机 404 实锤）。
    private static func normalizedAuthEndpoint(from urlString: String) -> URL? {
        guard var comps = URLComponents(string: urlString) else { return nil }
        if comps.scheme?.lowercased() != "https" {
            return nil
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
