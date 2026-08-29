import Foundation
import CryptoKit

/// 获取 Anisette Data（Apple 设备认证数据）的 v3 流程实现。
/// 参考 GetMoreRam / SideStore 的 Anisette v3 协议，纯原生实现（无第三方依赖）。
///
/// - 若钥匙串中已有 `identifier` + `adiPb`（来自 SideStore 账户导入或上一次的成功配置），
///   直接走 `/v3/get_headers`。
/// - 否则执行一次完整的 WebSocket 配给（provisioning）流程，把 `adiPb` 存入钥匙串后再取 headers。
final class AnisetteProvider {
    static let shared = AnisetteProvider()

    private let keychain = EscapeKeychain(service: "com.ipaside.escapeos.memorylimit")
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // v0.2.114：Anisette 服务器偶发无响应会导致整个页面卡在「正在加载团队…」。
        // 给该 session 下所有请求（含 WebSocket receive）统一设 30 秒无活动超时，
        // 作为单个请求显式 timeoutInterval 的兜底。
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private var url: URL? { URL(string: UserDefaults.standard.string(forKey: "AnisetteServer") ?? "https://ani.stikstore.app") }

    private var clientInfo: String?
    private var userAgent: String?
    private var mdLu: String?
    private var deviceId: String?

    private init() {}

    /// 重置：signOut / 切换账号时调用。清空内存缓存并删除 keychain 里的
    /// identifier+adiPb，确保下一次登录重新走完整 provision 并重新生成 identifier。
    func reset() {
        clientInfo = nil
        userAgent = nil
        mdLu = nil
        deviceId = nil
        keychain.delete("identifier")
        keychain.delete("adiPb")
        LoginLogger.shared.log("… AnisetteProvider 重置（identifier/adiPb 已清除）")
    }

    // MARK: - 共享机器标识（v0.2.117）

    /// keychain 里当前 identifier 的原始 16 字节（IPA 侧载/Rust 复用同一台
    /// "虚拟机器"用）；无或损坏时返回 nil。
    var sharedMachineIdentifier: Data? {
        guard let s = keychain.string(for: "identifier"),
              let d = Data(base64Encoded: s), d.count == 16 else { return nil }
        return d
    }

    /// keychain 里当前 adiPb 的原始字节（base64 字符串解码）；无则 nil。
    var sharedAdiPb: Data? {
        guard let s = keychain.string(for: "adiPb") else { return nil }
        return Data(base64Encoded: s)
    }

    /// 统一失败出口：写诊断日志并返回带真实原因的错误（不再用笼统的 invalidAnisetteData）。

    /// 统一失败出口：写诊断日志并返回带真实原因的错误（不再用笼统的 invalidAnisetteData）。
    private func fail(_ stage: String, _ detail: String) -> AppleAPIError {
        LoginLogger.shared.log("❌ Anisette[\(stage)]: \(detail)")
        return AppleAPIError.customError(code: -22421, message: "Anisette \(stage)失败: \(detail)")
    }

    /// 构造带 Apple 设备头的请求（对齐 GetMoreRam `buildAppleRequest`）。
    /// gsa lookup / midStartProvisioning / midFinishProvisioning 都必须带这些头，
    /// 否则 Apple 返回 404（此前裸 GET 的根因）。
    private func makeAppleRequest(url: URL) throws -> URLRequest {
        guard let clientInfo, let userAgent, let mdLu, let deviceId else {
            throw fail("provision", "缺少 client_info 字段（未先 fetchClientInfo）")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(mdLu, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(deviceId, forHTTPHeaderField: "X-Mme-Device-Id")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        request.setValue(formatter.string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation(), forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }

    func getAnisetteData(refresh: Bool = false) async throws -> AnisetteData {
        if refresh {
            clientInfo = nil; userAgent = nil; mdLu = nil; deviceId = nil
        }
        LoginLogger.shared.log("▶ getAnisetteData(refresh=\(refresh)) url=\(url?.absoluteString ?? "nil")")
        guard url != nil else { throw fail("入口", "Anisette 服务器地址为空") }
        if let identifier = keychain.string(for: "identifier"),
           let adiPb = keychain.string(for: "adiPb") {
            LoginLogger.shared.log("✓ 命中已缓存 identifier+adiPb，直接 get_headers")
            return try await fetchAnisetteV3(identifier: identifier, adiPb: adiPb)
        }
        LoginLogger.shared.log("… 无缓存凭证，走完整 WebSocket provision")
        return try await provision()
    }

    // MARK: - 服务器轮换 + 失败重试

    /// 当前 Anisette 服务器地址（供日志/展示用）。
    var currentServer: String {
        UserDefaults.standard.string(forKey: "AnisetteServer") ?? "https://ani.stikstore.app"
    }

    /// 切换到内置服务器列表中的下一个，并持久化到 `AnisetteServer`。
    /// 返回切换后的地址；列表为空时返回 nil。
    @discardableResult
    private func rotateServer() -> String? {
        let servers = MemoryLimitSettings.anisetteServers
        guard !servers.isEmpty else { return nil }
        let current = currentServer
        let next: String
        if let idx = servers.firstIndex(of: current) {
            next = servers[(idx + 1) % servers.count]
        } else {
            next = servers[0]
        }
        UserDefaults.standard.set(next, forKey: "AnisetteServer")
        LoginLogger.shared.log("… Anisette 服务器切换：\(current) → \(next)")
        return next
    }

    /// **带重试与服务器轮换的入口**，登录 / 团队列表等场景应优先调用它。
    ///
    /// 背景：Anisette v3 的 provisioning 会被 Apple 或中间服务器明确拒绝，
    /// 典型如 `unknown session (-45025)`、`invalid Trust Key (-45003)`，
    /// 以及 WebSocket 中途 `Socket未连接`。这些**绝大多数是单个 Anisette 服务器
    /// 的问题**（与 Apple 的 trust key 不同步、被风控、或会话过期），换一个
    /// 服务器重试通常就能过。v0.2.114 加的超时只解决"卡死"，解决不了这类
    /// "服务器明确拒绝"，所以这里补上重试 + 轮换。
    ///
    /// 每次重试前会 `reset()`：清掉内存缓存与 keychain 里的 identifier/adiPb，
    /// 强制重新生成 identifier 并对新服务器走完整 provision，避免拿旧会话重试。
    func getAnisetteDataWithFallback(refresh: Bool = false, maxAttempts: Int = 3) async throws -> AnisetteData {
        let originalServer = currentServer
        let started = Date()
        // v0.2.116：整体时间预算。就算某个请求没被单条 timeout 拦住（例如 WebSocket
        // 在握手后长时间不发消息），超预算也直接放弃，绝不把 UI 永久留在 loading。
        let budget: TimeInterval = 75
        var lastError: Error?
        var attempt = 0
        while attempt < maxAttempts {
            do {
                return try await getAnisetteData(refresh: refresh)
            } catch {
                lastError = error
                attempt += 1
                let elapsed = Date().timeIntervalSince(started)
                guard attempt < maxAttempts, elapsed < budget else { break }
                LoginLogger.shared.log("⚠ Anisette 第 \(attempt)/\(maxAttempts) 次失败，换服务器重试")
                reset()
                rotateServer()
            }
        }
        // 全部失败：把服务器还原成用户原本配置的地址。
        // 否则失败过程中轮换到的坏服务器会被固化，之后每次进页面都先撞它。
        if currentServer != originalServer {
            UserDefaults.standard.set(originalServer, forKey: "AnisetteServer")
            LoginLogger.shared.log("… 已还原 Anisette 服务器为 \(originalServer)")
        }
        let detail = (lastError as? AppleAPIError)?.errorDescription
            ?? lastError?.localizedDescription
            ?? "未知原因"
        LoginLogger.shared.log("❌ Anisette 已尝试 \(maxAttempts) 个服务器仍失败（耗时 \(Int(Date().timeIntervalSince(started)))s）")
        throw AppleAPIError.customError(
            code: -22421,
            message: "Anisette 连续 \(maxAttempts) 个服务器均失败（最后错误：\(detail)）。\n"
                + "可到「更多 → 设置 → Anisette 服务器」手动换一个，或稍后重试。"
        )
    }

    // MARK: - V3: client_info

    private func fetchClientInfo() async throws {
        // 先检查 keychain 里的 identifier 是否仍有效。 signOut 会删 identifier，
        // 但 AnisetteProvider 的内存缓存可能还在，此时必须重新生成 identifier，
        // 否则 provision 到 GiveIdentifier 时会从 keychain 读不到而报 -22421。
        let hasValidIdentifier: Bool = {
            guard let existing = keychain.string(for: "identifier") else { return false }
            guard let decoded = Data(base64Encoded: existing), decoded.count == 16 else { return false }
            return true
        }()

        if clientInfo != nil, userAgent != nil, mdLu != nil, deviceId != nil, hasValidIdentifier {
            return
        }

        guard let base = url else { throw fail("client_info", "服务器地址为空") }

        // client_info / user_agent 是设备描述，基本不变。只在内存缓存缺失时拉取。
        if clientInfo == nil || userAgent == nil {
            let clientInfoURL = base.appendingPathComponent("v3").appendingPathComponent("client_info")
            var clientInfoRequest = URLRequest(url: clientInfoURL)
            // v0.2.116：client_info 只是取设备描述字符串，正常几百毫秒就返回。
            // 服务器不可达时 30 秒太长，会让「正在加载团队…」转很久；缩到 10 秒，
            // 让失败快速暴露并进入换服务器重试。
            clientInfoRequest.timeoutInterval = 10
            let (data, response) = try await session.data(for: clientInfoRequest)
            let http = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard http == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let ci = json["client_info"], let ua = json["user_agent"] else {
                let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                throw fail("client_info", "HTTP \(http) 响应异常: \(preview)")
            }
            clientInfo = ci
            userAgent = ua
            LoginLogger.shared.log("✓ client_info OK: \(ci) / \(ua)")
        } else if !hasValidIdentifier {
            LoginLogger.shared.log("… 内存缓存命中但 keychain identifier 已清除，重新生成")
        }

        // identifier 必须以 base64 字符串存储（EscapeKeychain.string(for:) 用 UTF-8 解码，
        // 存原始字节会解码失败 → 登录报「Anisette数据无效或已过期」）。
        // 兼容清理：旧版本可能遗留了原始字节的坏数据，解码失败时重新生成。
        var identifier: String? = nil
        if hasValidIdentifier, let existing = keychain.string(for: "identifier") {
            identifier = existing
        }
        if identifier == nil {
            keychain.delete("identifier")
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw fail("identifier", "SecRandomCopyBytes 失败")
            }
            let newIdentifier = Data(bytes).base64EncodedString()
            keychain.set(newIdentifier, for: "identifier")
            identifier = newIdentifier
            LoginLogger.shared.log("… 重新生成 identifier（旧值缺失或损坏）")
        }
        guard let identifier else { throw fail("identifier", "无法读取 identifier") }
        guard let decoded = Data(base64Encoded: identifier) else {
            throw fail("identifier", "identifier 不是合法 base64: \(identifier.prefix(12))…")
        }
        mdLu = Data(SHA256.hash(data: decoded)).map { String(format: "%02X", $0) }.joined()
        let uuid = decoded.withUnsafeBytes { $0.loadUnaligned(as: UUID.self) }
        deviceId = uuid.uuidString.uppercased()
        LoginLogger.shared.log("✓ identifier=\(identifier.prefix(12))… mdLu=\(mdLu?.prefix(12) ?? "") deviceId=\(deviceId ?? "")")
    }

    // MARK: - V3: get_headers

    func fetchAnisetteV3(identifier: String, adiPb: String) async throws -> AnisetteData {
        try await fetchClientInfo()
        guard let base = url else { throw fail("get_headers", "服务器地址为空") }
        var request = URLRequest(url: base.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        // v0.2.116：get_headers 是一次简单 POST，15 秒足够；失败快才能快速换服务器。
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["identifier": identifier, "adi_pb": adiPb])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        LoginLogger.shared.log("▶ get_headers POST \(base.appendingPathComponent("v3").appendingPathComponent("get_headers").absoluteString)")
        let (data, response) = try await session.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        LoginLogger.shared.log("← get_headers HTTP \(http): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        return try await extractAnisetteData(data, response as? HTTPURLResponse, v3: true)
    }

    private func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> AnisetteData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw fail("get_headers", "响应不是 JSON: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        if v3, let result = json["result"] as? String, result == "GetHeadersError",
           let message = json["message"] as? String {
            LoginLogger.shared.log("⚠ get_headers 返回错误: \(message)")
            if message.contains("-45061") {
                keychain.delete("adiPb")
                LoginLogger.shared.log("… adiPb 已过期(-45061)，删除后重新 provision")
                return try await provision()
            }
            throw AppleAPIError.customError(code: -1, message: "Anisette 服务器: \(message)")
        }

        var formatted: [String: String] = ["deviceSerialNumber": "0"]
        if let v = json["X-Apple-I-MD-M"] as? String { formatted["machineID"] = v }
        if let v = json["X-Apple-I-MD"] as? String { formatted["oneTimePassword"] = v }
        if let v = json["X-Apple-I-MD-RINFO"] as? String { formatted["routingInfo"] = v }
        else if let v = json["X-Apple-I-MD-RINFO"] as? Int { formatted["routingInfo"] = String(v) }

        if v3 {
            formatted["deviceDescription"] = clientInfo ?? ""
            formatted["localUserID"] = mdLu ?? ""
            formatted["deviceUniqueIdentifier"] = deviceId ?? ""
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.calendar = Calendar(identifier: .gregorian)
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formatted["date"] = fmt.string(from: Date())
            formatted["locale"] = Locale.current.identifier
            formatted["timeZone"] = TimeZone.current.abbreviation() ?? "GMT"
        } else {
            if let v = json["X-MMe-Client-Info"] as? String { formatted["deviceDescription"] = v }
            if let v = json["X-Apple-I-MD-LU"] as? String { formatted["localUserID"] = v }
            if let v = json["X-Mme-Device-Id"] as? String { formatted["deviceUniqueIdentifier"] = v }
            if let v = json["X-Apple-I-Client-Time"] as? String { formatted["date"] = v }
            if let v = json["X-Apple-Locale"] as? String { formatted["locale"] = v }
            if let v = json["X-Apple-I-TimeZone"] as? String { formatted["timeZone"] = v }
        }

        guard let jsonData = try? JSONEncoder().encode(formatted),
              let anisette = try? JSONDecoder().decode(AnisetteData.self, from: jsonData) else {
            throw fail("get_headers", "Anisette 字段组装/解码失败: \(formatted.keys.sorted().joined(separator: ","))")
        }
        LoginLogger.shared.log("✓ AnisetteData 组装成功: md=\(anisette.machineID.prefix(12))… otp=\(anisette.oneTimePassword.prefix(12))… rinfo=\(anisette.routingInfo)")
        return anisette
    }

    // MARK: - V3: provisioning（首次使用、无 adi.pb 时）

    private func provision() async throws -> AnisetteData {
        LoginLogger.shared.log("▶ provision 开始")
        try await fetchClientInfo()
        let request = try makeAppleRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!)
        let (data, response) = try await session.data(for: request)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard http == 200,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
              let startStr = plist["urls"]?["midStartProvisioning"] as? String,
              let endStr = plist["urls"]?["midFinishProvisioning"] as? String,
              let startURL = URL(string: startStr), let endURL = URL(string: endStr) else {
            throw fail("provision", "gsa lookup 异常(HTTP \(http)): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        LoginLogger.shared.log("✓ gsa lookup 拿到 mid 端点")
        let adiPb = try await startProvisioningSession(startURL: startURL, endURL: endURL)
        keychain.set(adiPb, for: "adiPb")
        guard let identifier = keychain.string(for: "identifier") else {
            throw fail("provision", "provision 后读取 identifier 失败")
        }
        return try await fetchAnisetteV3(identifier: identifier, adiPb: adiPb)
    }

    private func startProvisioningSession(startURL: URL, endURL: URL) async throws -> String {
        guard let base = url else { throw fail("provision", "服务器地址为空") }
        var comps = URLComponents(url: base.appendingPathComponent("v3").appendingPathComponent("provisioning_session"), resolvingAgainstBaseURL: false)!
        if comps.scheme == "https" { comps.scheme = "wss" } else if comps.scheme == "http" { comps.scheme = "ws" }
        guard let wsURL = comps.url else { throw fail("provision", "WebSocket URL 构建失败") }
        var wsReq = URLRequest(url: wsURL)
        wsReq.timeoutInterval = 30
        LoginLogger.shared.log("▶ WebSocket 连接 \(wsURL.absoluteString)")
        let socket = session.webSocketTask(with: wsReq)
        socket.resume()
        return try await withCheckedThrowingContinuation { continuation in
            receiveProvisioningMessages(from: socket, startURL: startURL, endURL: endURL, continuation: continuation)
        }
    }

    private func receiveProvisioningMessages(from socket: URLSessionWebSocketTask,
                                             startURL: URL, endURL: URL,
                                             continuation: CheckedContinuation<String, Error>) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                LoginLogger.shared.log("❌ WebSocket 接收失败: \(err.localizedDescription)")
                continuation.resume(throwing: self.fail("provision", "WebSocket 接收失败: \(err.localizedDescription)"))
                socket.cancel(with: .normalClosure, reason: nil)
            case .success(let message):
                switch message {
                case .string(let str):
                    Task {
                        do {
                            let done = try await self.handleProvisioningMessage(str, socket: socket,
                                                                               startURL: startURL, endURL: endURL,
                                                                               continuation: continuation)
                            if !done {
                                self.receiveProvisioningMessages(from: socket, startURL: startURL, endURL: endURL, continuation: continuation)
                            }
                        } catch {
                            continuation.resume(throwing: error)
                            socket.cancel(with: .normalClosure, reason: nil)
                        }
                    }
                default:
                    LoginLogger.shared.log("❌ WebSocket 收到非文本消息")
                    continuation.resume(throwing: self.fail("provision", "WebSocket 收到非文本消息"))
                    socket.cancel(with: .normalClosure, reason: nil)
                }
            }
        }
    }

    private func handleProvisioningMessage(_ str: String, socket: URLSessionWebSocketTask,
                                           startURL: URL, endURL: URL,
                                           continuation: CheckedContinuation<String, Error>) async throws -> Bool {
        guard let data = str.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else {
            throw fail("provision", "服务端消息无法解析: \(str.prefix(200))")
        }
        LoginLogger.shared.log("← WebSocket: \(str.prefix(200))")
        switch result {
        case "GiveIdentifier":
            guard let identifier = keychain.string(for: "identifier") else { throw fail("provision", "GiveIdentifier 时无 identifier") }
            try await socket.send(.string(String(data: try JSONSerialization.data(withJSONObject: ["identifier": identifier]), encoding: .utf8)!))
            return false
        case "GiveStartProvisioningData":
            let spim = try await fetchProvisioningData(url: startURL, body: ["Header": [:], "Request": [:]])
            try await socket.send(.string(String(data: try JSONSerialization.data(withJSONObject: ["spim": spim]), encoding: .utf8)!))
            return false
        case "GiveEndProvisioningData":
            guard let cpim = json["cpim"] as? String else { throw fail("provision", "GiveEndProvisioningData 无 cpim") }
            let endData = try await fetchEndProvisioningData(url: endURL, cpim: cpim)
            try await socket.send(.string(String(data: try JSONSerialization.data(withJSONObject: endData), encoding: .utf8)!))
            return false
        case "ProvisioningSuccess":
            guard let adiPb = json["adi_pb"] as? String else { throw fail("provision", "ProvisioningSuccess 无 adi_pb") }
            LoginLogger.shared.log("✓ provision 成功，adi_pb=\(adiPb.prefix(16))…")
            socket.cancel(with: .normalClosure, reason: nil)
            continuation.resume(returning: adiPb)
            return true
        default:
            if result.contains("Error") || result.contains("Invalid") ||
               result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                let raw = json["message"] as? String ?? ""
                // -45025 unknown session / -45003 invalid Trust Key 都是**单个
                // Anisette 服务器**与 Apple trust 不同步或其会话过期，换服务器
                // 通常即可通过。这里打点说明，重试逻辑见 getAnisetteDataWithFallback。
                if raw.contains("-45025") || raw.contains("-45003") || raw.contains("-45061") {
                    LoginLogger.shared.log("… 该 Anisette 服务器被 Apple 拒绝（\(raw)），属可重试错误，将换服务器")
                }
                throw fail("provision", "服务端返回 \(result): \(raw)")
            }
            return false
        }
    }

    private func fetchProvisioningData(url: URL, body: [String: Any]) async throws -> String {
        var req = try makeAppleRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        let (data, response) = try await session.data(for: req)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard http == 200,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
              let spim = plist["Response"]?["spim"] as? String else {
            throw fail("provision", "midStartProvisioning(HTTP \(http)): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return spim
    }

    private func fetchEndProvisioningData(url: URL, cpim: String) async throws -> [String: String] {
        let body: [String: Any] = ["Header": [:], "Request": ["cpim": cpim]]
        var req = try makeAppleRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        let (data, response) = try await session.data(for: req)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard http == 200,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
              let ptm = plist["Response"]?["ptm"] as? String,
              let tk = plist["Response"]?["tk"] as? String else {
            throw fail("provision", "midFinishProvisioning(HTTP \(http)): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return ["ptm": ptm, "tk": tk]
    }
}
