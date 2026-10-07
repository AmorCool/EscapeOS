//
//  EntDownload.swift
//  ApplePackage
//
//  `ent/download` 端点 —— 免登录下载链的**首选**端点。
//
//  移植来源：ipatool `pkg/appstore/appstore_kbsync.go`（PR #554 系列）
//           + `internal/sap/machine/kbsync.go`（kbsync 生成）。
//
//  ## 上游逻辑（`appstore_download_product.go:31-70`）
//
//  ```
//  if t.kbsyncGenerator != nil {
//      bag, err := t.fetchURLBag(guid)          // ① 取 bag（同一个 bag.xml，只在内存里用）
//      if err == nil && bag.EntDownloadEndpoint != "" {
//          res, platform, err := t.sendPreferredDownload(...)   // ② 走 ent/download
//          if err == nil { return res, platform, nil }          // ③ 成功就直接返回
//      }
//  }
//  ... 落到 volumeStore → redownload → updateProduct 的旧链
//  ```
//
//  也就是说 `ent/download` 是**贴在前面的、可失败退出的**一跳：
//  资产缺失 / 网络失败 / 响应不合规 → 悄悄落回旧链，**不报错**。
//  这一点必须保留 —— 否则 kbsync 还没打通的情况下会把整条下载链拖死。
//
//  ## 为什么它比旧链好
//
//  旧链（volumeStore → redownload）打的是 `pXX-buy` / `downloaddispatch` 的
//  业务端点，Apple 会按账号授权**现算** → 该账号没下载记录时挂 9–10 秒再回
//  502（真机实测）。`ent/download` 走的是**挂 kbsync 的机器绑定凭据**，
//  直接按机器身份出包，不依赖账号的现算授权。
//
//  ## 三个硬前置（上游 `sendEntDownload` 逐条校验）
//
//  1. **guid 的十六进制解码必须恰好 6 字节** —— 解码失败或长度不符直接拒绝；
//  2. **DSID 必须是非零十进制数** —— `ParseUint` 失败或为 0 直接拒绝；
//  3. **versionID 非空** —— 空版本会调 `lookupLatestExternalVersionID` 补，
//     补不到就报错（绝不发不带版本号的请求）。
//
//  前两条在这里也拦一次：它们能在请求前判定，早点报错比让 guest 里跑出
//  一个看不懂的码好得多。
//

import Foundation

/// kbsync 生成器 —— 宿主注入（要跑 Unicorn 解释 storeagent，vendor 层做不到）。
///
/// 与 `Configuration.sapSignerFactory` 同一个模式：vendor 只依赖抽象，
/// 宿主 app 在启动时装配一次。返回 nil 或抛错 → `ent/download` 路径整体跳过，
/// 落回旧链（**不**让下载失败）。
///
/// `@Sendable`：它会被跨 actor 调用（下载在后台任务里），Swift 6 严格并发下
/// 不加这个会被判为「非 Sendable 闭包被跨隔离域传递」。
public typealias KBSyncGenerator = @Sendable (_ hardwareID: Data, _ dsid: UInt64) async throws -> Data

public extension Configuration {
    /// 宿主注入的 kbsync 生成器。nil 表示「本机还跑不了 `ent/download`」。
    nonisolated(unsafe) static var kbsyncGenerator: KBSyncGenerator?
}

public enum EntDownload {
    /// 端点路径 —— 上游 `entDownloadPath`（`appstore_kbsync.go:17`）。
    public static let path = "/WebObjects/DownloadDispatch.woa/wa/ent/download"

    /// bag.xml 地址 —— 与登录链用的是同一个（`SignedStoreAuthenticator` 里的那份）。
    ///
    /// **必须带 guid 查询串**：Apple 按它决定 `urlBag` 里的 pod 相关端点。
    static func bagURL(deviceIdentifier: String) -> URL? {
        URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(deviceIdentifier)")
    }

    /// 从 bag 里取 `ent/download` 的端点。
    ///
    /// 键名是 **`volumeStoreDownloadProduct`** —— 名字看起来像旧端点，但值就是
    /// ent/download 的完整 URL（上游 `urlBag` 结构体里那个字段的 plist 名，
    /// 见 `appstore_bag.go:81`；测试 `appstore_kbsync_test.go:21/70` 也是这个键）。
    ///
    /// - Returns: 端点字符串；bag 拿不到 / 键缺失时 nil（调用方据此跳过 ent/download 那一跳）。
    static func endpointFromBag(
        client: HTTPClient,
        account: inout AppStoreAccount,
        deviceIdentifier: String
    ) async -> String? {
        guard let url = bagURL(deviceIdentifier: deviceIdentifier) else { return nil }
        do {
            var request = HTTPClient.Request(url: url, method: .GET)
            // bag.xml 只对 Configurator UA 返回完整键（见 Configuration.bagUserAgent 的注释）。
            request.headers.add(name: "User-Agent", value: Configuration.bagUserAgent)
            let response = try await client.execute(request: request).get()
            account.cookie.mergeCookies(response.cookies)
            guard response.status == .ok, let data = response.body?.data else {
                storeLog("ent/download：bag 拉取失败（HTTP \(response.status.code)）")
                return nil
            }
            // bag.xml 把 plist 裹在 <Document><Protocol> 里，所以要先把 <plist> 段抠出来。
            //
            // ⚠️ **不能**用宿主里的 `StoreAuthenticationProtocol.plist`：那是宿主层类型，
            // vendor 反向依赖它会打破「vendor 只向下依赖」这条线（也会让这个文件
            // 无法单独被 ApplePackage 使用）。抠取逻辑只有三行，就地实现。
            var payload = data
            if let xml = String(data: data, encoding: .utf8),
               let start = xml.range(of: "<plist"), let end = xml.range(of: "</plist>"),
               start.lowerBound < end.upperBound {
                payload = Data(xml[start.lowerBound..<end.upperBound].utf8)
            }
            guard let bag = (try? PropertyListSerialization.propertyList(from: payload, format: nil))
                as? [String: Any]
            else {
                storeLog("ent/download：bag 不是合法 plist")
                return nil
            }
            let nested = bag["urlBag"] as? [String: Any] ?? [:]
            let value = (bag["volumeStoreDownloadProduct"] as? String)
                ?? (nested["volumeStoreDownloadProduct"] as? String)
                ?? ""
            if value.isEmpty {
                storeLog("ent/download：bag 里没有 volumeStoreDownloadProduct 键")
                return nil
            }
            return value
        } catch is CancellationError {
            return nil
        } catch {
            storeLog("ent/download：bag 拉取异常（\(error.localizedDescription)）")
            return nil
        }
    }

    /// ent/download 请求体里 `serialNumber` 的前缀 —— 上游 `sendEntDownloadRequest`：
    /// ```go
    /// serial := append([]byte{0x54, 0xc8, 0xb0, 0xa9, 0x88}, hardwareID[2:]...)
    /// ```
    /// 5 个固定字节 + **hardwareID 的后 4 位**（即 6 字节 guid 去掉前 2 位），
    /// 然后整体 base64。
    static let serialPrefix: [UInt8] = [0x54, 0xc8, 0xb0, 0xa9, 0x88]

    /// ent/download 专用的 UA（上游 `appstore_kbsync.go:121`，与被 redownload 链用的
    /// `Configurator/2.17` **不同**，是 2.18）。
    static let userAgent = "Configurator/2.18 (Macintosh; OS X 15.3.2; 24D81) AppleWebKit/0620.2.4.11.6"

    /// `[计时]` 日志用 —— 与锚点的毫秒差（`LoginLogger` 自带绝对时间戳，这里只让每段耗时一眼可见）。
    static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// 取包的完整流程。**失败一律返回 nil，由调用方落回旧链。**
    ///
    /// - Parameters:
    ///   - endpoint: bag 里 `volumeStoreDownloadProduct` 键的值（挂 ent/download 路径的 **base**）。
    ///   - externalVersionID: 已固定的版本号；**空字符串会被拒绝**（上游硬门 3）。
    /// - Returns: 与旧链同形状的响应字典（`songList` 恰好 1 项）；不可用时 nil。
    public static func fetchProduct(
        client: HTTPClient,
        account: inout AppStoreAccount,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String,
        endpoint bagEndpoint: String
    ) async throws -> [String: Any]? {
        guard let generator = Configuration.kbsyncGenerator else {
            storeLog("ent/download 跳过：宿主未装配 kbsync 生成器")
            return nil
        }

        // ── 硬前置 ①②③ ──────────────────────────────────────────────────────
        // 上游在 `sendEntDownload` 里逐条 throw；我们这里**返回 nil 而不是 throw**，
        // 因为按上游语义「ent/download 走不通」就该安静落回旧链 ——
        // 这条链是**附加**在前面的一跳，不是替代。
        guard let hardwareID = Data(hexString: deviceIdentifier), hardwareID.count == 6 else {
            storeLog("ent/download 跳过：设备标识不是 6 字节十六进制（\(deviceIdentifier.count) 位）")
            return nil
        }
        guard let dsid = UInt64(account.directoryServicesIdentifier), dsid != 0 else {
            storeLog("ent/download 跳过：账号 DSID 不是非零十进制数")
            return nil
        }
        guard !externalVersionID.isEmpty else {
            storeLog("ent/download 跳过：版本号为空（上游禁止不带版本的下载请求）")
            return nil
        }
        guard !account.passwordToken.isEmpty else {
            storeLog("ent/download 跳过：会话没有 X-Token")
            return nil
        }

        // ── 校验 bag 给的端点 ────────────────────────────────────────────────
        //
        // ⚠️ bag 里 `volumeStoreDownloadProduct` 这个键名有误导性：它的值**本身就是
        // ent/download 的完整 URL**（含 `/WebObjects/DownloadDispatch.woa/wa/ent/download`
        // 路径），host 是 `downloaddispatch.itunes.apple.com` —— **不是** pXX-buy。
        // 上游 `newDownloadEndpoint(endpointURL, entDownloadPath)` 的校验逐条对应：
        //   scheme == https / host == downloaddispatch.itunes.apple.com /
        //   path == entDownloadPath / 无 RawQuery / 无 Fragment / 无 User。
        // 我们照搬（见 `appstore_kbsync_test.go:21` 的 `testEntDownloadEndpoint`）。
        guard let parsed = URLComponents(string: bagEndpoint),
              parsed.scheme?.lowercased() == "https",
              parsed.host?.lowercased() == "downloaddispatch.itunes.apple.com",
              parsed.path == path,
              parsed.query == nil, parsed.fragment == nil, parsed.user == nil
        else {
            storeLog("ent/download 跳过：bag 给的端点不合规（\(bagEndpoint)）")
            return nil
        }

        // ── 生成 kbsync（跑 Unicorn，可能要几秒）───────────────────────────────
        //
        // v0.3.5xx：这一段是本任务的核心盲区 —— 29.6s 的 `ent/download` 到底花在
        // kbsync 冷缓存（跑 Unicorn）还是网络，此前无埋点、答不了。这里计时；
        // 「冷/热缓存」的判定由 `KBSyncProvider.generate` 在 AppleID 板块打。
        let kbsyncStarted = Date()
        let blob: Data
        do {
            blob = try await generator(hardwareID, dsid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            storeLog("ent/download 跳过：kbsync 生成失败（\(error.localizedDescription)）")
            return nil
        }
        storeLog("[计时] ent/download kbsync 生成 耗时=\(Self.elapsedMs(since: kbsyncStarted))ms 字节=\(blob.count)")
        guard !blob.isEmpty else {
            storeLog("ent/download 跳过：kbsync 为空")
            return nil
        }

        // ── 组 serialNumber：5 个固定字节 + hardwareID 后 4 位 → base64 ─────────
        let buildStarted = Date()
        var serial = serialPrefix
        serial.append(contentsOf: hardwareID.dropFirst(2))
        let serialBase64 = Data(serial).base64EncodedString()

        // ── 组请求 ────────────────────────────────────────────────────────────
        // 注意两点与旧链不同：
        //   · `Content-Type` 是 **urlencoded**（不是 plist），但体仍是 XML plist；
        //   · 带 `X-Token`（= passwordToken）。
        // client 已按 `.disallow` 建（见 `Download.download`），所以 X-Token
        // 不会被跟随重定向带到别的域 —— 等价于上游的 `request.NoRedirects = true`。
        // 上游 `http.Request{URL: fmt.Sprintf("%s?guid=%s", endpoint.baseURL, guid)}` ——
        // 端点是完整 URL，只是把 guid 拼在查询串上。
        let url = "\(bagEndpoint)?guid=\(deviceIdentifier)"

        var headers: [(String, String)] = [
            ("Content-Type", "application/x-www-form-urlencoded; charset=utf-8"),
            ("User-Agent", userAgent),
            ("Accept-Language", Locale.preferredLanguages.prefix(3).joined(separator: ", ")),
            ("iCloud-DSID", account.directoryServicesIdentifier),
            ("X-Dsid", account.directoryServicesIdentifier),
            ("X-Token", account.passwordToken),
        ]
        if !account.store.isEmpty {
            headers.append(("X-Apple-Store-Front", account.requestStoreFront))
        }
        if let cookieURL = URL(string: url) {
            for item in account.cookie.buildCookieHeader(cookieURL) {
                headers.append(item)
            }
        }

        let body = try PropertyListSerialization.data(
            fromPropertyList: [
                "creditDisplay": "",
                "guid": deviceIdentifier,
                "kbsync": blob,
                "salableAdamId": String(app.id),
                "serialNumber": serialBase64,
                "externalVersionId": externalVersionID,
            ],
            format: .xml,
            options: 0
        )

        let request = try HTTPClient.Request(
            url: url,
            method: .POST,
            headers: HTTPHeaders(headers),
            body: .data(body)
        )
        storeLog("[计时] ent/download 请求构造 耗时=\(Self.elapsedMs(since: buildStarted))ms")

        // 网络往返本身由 shim 的统一逐请求耗时日志覆盖
        // （`[计时] HTTP POST downloaddispatch.itunes.apple.com/… 耗时=…ms 状态=…`），
        // 这里只标记「响应解析」段的起点。
        let response: HTTPClient.Response
        do {
            response = try await client.execute(request: request).get()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            storeLog("ent/download 请求失败：\(error.localizedDescription)")
            return nil
        }
        let parseStarted = Date()

        account.cookie.mergeCookies(response.cookies)
        if let pod = response.headers.first(name: "pod"), Int(pod) != nil { account.pod = pod }
        if let store = response.headers.first(name: "X-Set-Apple-Store-Front"), !store.isEmpty {
            account.fullStoreFront = store
        }

        storeLog("ent/download → HTTP \(response.status.code)")

        guard response.status == .ok else {
            let snippet = String(
                data: (response.body?.data ?? Data()).prefix(256), encoding: .utf8
            ) ?? "(非 UTF-8)"
            storeLog("ent/download 非 200：body=\(snippet.prefix(160))")
            return nil
        }

        guard let data = response.body?.data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any]
        else {
            storeLog("ent/download 响应不是合法 plist")
            return nil
        }

        // ── 结构化失败 → 也算「没拿到」，落回旧链 ──────────────────────────────
        if !(dict["failureType"] as? String ?? "").isEmpty {
            storeLog("ent/download 结构化失败：\(StoreDownloadEndpoint.summary(dict))")
            return nil
        }
        if !(dict["customerMessage"] as? String ?? "").isEmpty {
            storeLog("ent/download 客户消息：\(StoreDownloadEndpoint.summary(dict))")
            return nil
        }

        // ── 响应校验（上游 `validateVersionedDownloadResponse`，source="ent/download"）──
        guard let items = dict["songList"] as? [[String: Any]], items.count == 1 else {
            storeLog("ent/download 响应 songList 不是恰好 1 项")
            return nil
        }
        guard let metadata = items[0]["metadata"] as? [String: Any] else {
            storeLog("ent/download 响应缺少 metadata")
            return nil
        }
        if let itemID = metadata["itemId"], "\(itemID)" != "\(app.id)" {
            storeLog("ent/download 响应的 itemId 不匹配")
            return nil
        }
        if let ext = metadata["softwareVersionExternalIdentifier"], "\(ext)" != externalVersionID {
            storeLog("ent/download 响应的版本不匹配")
            return nil
        }
        if let bundle = metadata["softwareVersionBundleId"] as? String,
           !app.bundleID.isEmpty, bundle != app.bundleID {
            storeLog("ent/download 响应的 bundleID 不匹配")
            return nil
        }
        // 上游在最后还要求 `res.Data.Items[0].URL != ""`（`items[0].URL` 为空视作失败）。
        guard let packageURL = items[0]["URL"] as? String, !packageURL.isEmpty else {
            storeLog("ent/download 响应没有包地址")
            return nil
        }

        storeLog("[计时] ent/download 响应解析 耗时=\(Self.elapsedMs(since: parseStarted))ms 命中")
        storeLog("ent/download 命中；\(StoreDownloadEndpoint.summary(dict)) 包地址 \(packageURL.prefix(60))…")
        return dict
    }
}

// MARK: - 十六进制解码

extension Data {
    /// 把偶数长度、全为十六进制字符的字符串解码成 `Data`；否则 nil。
    ///
    /// 不用 `Data(hexString:)` 之类的现成扩展 —— 本项目里之前没有，
    /// 加一个局部实现比引入新依赖清楚。**大小写都接受**
    /// （`deviceGuid` 的落盘格式在历史版本里两种都出现过）。
    init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
