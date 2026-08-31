import Foundation

// ─── v0.3.11：远程签名客户端（局域网 PC 上的 EscapeSapServer.exe）──────────
//
// 架构：SAP 签名需要模拟执行 CommerceKit x86-64（Unicorn TCG = JIT），iOS 侧
// 受 JIT 权限限制（无 JIT 物理不可行，StikDebug 附加在 iOS 27 beta 上不可靠）。
// 改为签名在 PC 上执行：PC 跑 EscapeSapServer.exe（Windows 原生，无 JIT 限制，
// 资产包在 PC 侧下载——iOS 磁盘配额/下载问题一并消除），EscapeOS 走局域网 HTTP。
//
// 协议（与 sapbridge/cmd/server/main.go 对齐）：
//   POST /v1/init  JSON {setupURL, certURL, version, hwIDBase64} → {"status":"ready"}
//   POST /v1/sign  <raw body>                                    → {"signature":"<base64>"}
//   POST /v1/close                                                  → {"status":"closed"}
//   GET  /health                                                    → {"status":"ok","ready":bool}

/// 远程签名错误（Authenticate 捕获后**直接中止登录**——服务器不可达/初始化失败时，
/// 回退未签名请求只会得到误导性的 Apple 403）。
struct SAPRemoteSignerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class RemoteSapSigner: SAPActionSigning {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession

    /// 初始化 = 让 PC 下载资产包并启动模拟器（首次 ~36MB，走 PC 网络）。
    init(baseURL: URL, config: SAPConfig, token: String? = nil) async throws {
        self.baseURL = baseURL
        self.token = token
        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = 900  // PC 侧首次资产下载 + 模拟器启动的宽裕窗口
        conf.timeoutIntervalForResource = 900
        session = URLSession(configuration: conf)

        struct InitRequest: Encodable {
            let setupURL: String
            let certURL: String
            let version: UInt32
            let hwIDBase64: String
        }
        let body = try JSONEncoder().encode(
            InitRequest(
                setupURL: config.setupURL.absoluteString,
                certURL: config.certificateURL.absoluteString,
                version: config.version,
                hwIDBase64: config.hardwareID.base64EncodedString()
            )
        )
        // 初始化失败 = 远程签名路径不可用 → 原样上抛给登录 UI（不回退未签名）
        _ = try Self.request("POST", url: baseURL.appendingPathComponent("v1/init"),
                             body: body, token: token, session: session)
    }

    /// 对请求体字节签名，返回 base64（作为 X-Apple-ActionSignature 头）。
    /// 协议要求同步——authenticate 在后台 Task 中调用，这里用信号量桥接。
    func sign(requestBody: Data) throws -> String {
        var result: Result<String, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        let baseURL = self.baseURL
        let token = self.token
        let session = self.session
        Task.detached(priority: .userInitiated) {
            do {
                let data = try await Self.request(
                    "POST", url: baseURL.appendingPathComponent("v1/sign"),
                    body: requestBody, token: token, session: session
                )
                let payload = try JSONDecoder().decode([String: String].self, from: data)
                guard let signature = payload["signature"] else {
                    throw SAPRemoteSignerError(message: "服务器响应缺少 signature 字段")
                }
                result = .success(signature)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    func close() {
        let baseURL = self.baseURL
        let token = self.token
        let session = self.session
        Task.detached(priority: .utility) {
            _ = try? Self.request("POST", url: baseURL.appendingPathComponent("v1/close"),
                                  body: Data(), token: token, session: session)
        }
    }

    // MARK: - HTTP

    private static func request(_ method: String, url: URL, body: Data,
                                token: String?, session: URLSession) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 60
        if let token { req.setValue(token, forHTTPHeaderField: "X-Sap-Token") }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? String(data: data.prefix(200), encoding: .utf8)
                ?? "HTTP \(code)"
            throw SAPRemoteSignerError(message: message)
        }
        return data
    }
}
