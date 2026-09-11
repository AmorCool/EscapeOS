import Foundation

/// v0.3.262：App Store 登录的 Go 实现（照抄 IPARanger / 上游 ipatool 的链路）.
///
/// 背景：Swift 旧登录链路（vendor ApplePackage.Authenticator，URLSession 栈 +
/// x-apple-plist Content-Type）被 Apple 边缘 WAF 秒拒（真机 2026-09-09 18:23：
/// 0.4s HTML 404/403，Wi-Fi 与蜂窝同拒）；而同网络下 IPARanger 捆绑的 Go 版
/// ipatool 形态可用。本类型把登录整体下沉到 Go：经 cgo 调用 libsap.a 的
/// `EscapeAppStoreLogin`（sapbridge/authappstore = 上游 pkg/appstore+pkg/http
/// 文件级照抄），请求由 Go 标准库 net/http/crypto-tls 发出 —— 报文形态
///（Content-Type: application/x-www-form-urlencoded、Go TLS 指纹、头集合与
/// 顺序、bag/init 端点、双层重试语义）与 IPARanger 完全一致。
///
/// SAP 签名复用本进程 Unicorn guest（authappstore 内部装配 internal/sap，
/// 资产包缓存目录与宿主 Caches 共用）。
enum GoAppStoreAuth {

    /// cgo 返回的 JSON 结构.
    private struct LoginResult: Decodable {
        struct Account: Decodable {
            var email: String?
            var passwordToken: String?
            var directoryServicesID: String?
            var name: String?
            var storeFront: String?
            var pod: String?
        }

        struct Cookie: Decodable {
            var name: String
            var value: String
            var domain: String?
            var path: String?
        }

        struct Diag: Decodable {
            var step: String
            var url: String
            var status: Int
            var elapsedMs: Int
            var detail: String?
        }

        var success: Bool
        var authCodeRequired: Bool
        var error: String?
        var account: Account?
        var cookies: [Cookie]?
        var diagnostics: [Diag]?
    }

    /// 阻塞执行一次完整登录（bag → SAP 签名器 → 双层重试 → 解析）。
    /// 调用方应在后台线程 Task.detached 中使用（SAP 初始化可能较慢）。
    /// - Parameters:
    ///   - email/password: Apple ID 凭据
    ///   - authCode: 2FA 验证码（可空）
    ///   - deviceIdentifier: 与 SAP 硬件标识同源的设备标识（hex 串）
    ///   - cacheDir: SAP 资产包缓存目录（宿主 Caches）
    static func login(
        email: String,
        password: String,
        code: String,
        deviceIdentifier: String,
        cacheDir: String
    ) throws -> AppStoreAccount {
        do {
            return try loginOnce(email: email, password: password, code: code, deviceIdentifier: deviceIdentifier, cacheDir: cacheDir)
        } catch {
            let desc = error.localizedDescription
            let isEdgeSoftReject = ["HTTP 404", "HTTP 503", "HTTP 204", "HTTP 403",
                                    "failed to retrieve redirect location", "redirect status"]
                .contains { desc.contains($0) }
            guard isEdgeSoftReject else { throw error }

            if code.isEmpty {
                // 无码登录被软拒：换新 guid 重试一轮（新 guid 新计数窗口）.
                LoginLogger.shared.log("[GoAuth] edge soft-reject, rotating device identifier and retrying once after 15s")
                AppStoreDownloadStore.shared.resetDeviceIdentifier()
                // 等待窗口回落后再打（16:35/16:36 日志：换 guid 后立即重打仍撞
                // 限流——IP/账号维度计数同样在热区）.
                Thread.sleep(forTimeInterval: 15)
                return try loginOnce(email: email, password: password, code: code, deviceIdentifier: Configuration.deviceIdentifier, cacheDir: cacheDir)
            }

            // 2FA 带码重试被软拒：验证码已下发且 30 分钟内有效，等 75s 让边缘
            // 限流窗口回落后原 guid 重试一次（Apple 对 authenticate 的限流极紧，
            // 21:04→21:05 间隔 30s 的带码重试实测撞 pod 403）.
            LoginLogger.shared.log("[GoAuth] edge soft-reject on 2FA attempt, waiting 75s before one retry")
            Thread.sleep(forTimeInterval: 75)
            return try loginOnce(email: email, password: password, code: code, deviceIdentifier: deviceIdentifier, cacheDir: cacheDir)
        }
    }

    /// 单次登录（bag → SAP 签名器 → 双层重试 → 解析）。
    /// 调用方应在后台线程 Task.detached 中使用（SAP 初始化可能较慢）。
    static func loginOnce(
        email: String,
        password: String,
        code: String,
        deviceIdentifier: String,
        cacheDir: String
    ) throws -> AppStoreAccount {
        LoginLogger.shared.log("[GoAuth] 开始登录（Go 栈，上游 ipatool 形态）: \(email)（含验证码：\(code.isEmpty ? "否" : "是")）")

        // SAP 状态条：Go 侧 assets.Load 会写进度（SapGetProgress），登录期间
        // 开轮询驱动 UI（与旧 Swift 工厂闭包同款节奏）.
        SapProgressPoller.shared.start()
        defer { SapProgressPoller.shared.stop() }

        // NSString.utf8String：同步 cgo 调用期间由 autoreleasepool 保证有效，
        // 免手动 malloc/free（strdup + deallocate 与 free 的 ABI 不保证一致）.
        guard let emailC = (email as NSString).utf8String,
              let passwordC = (password as NSString).utf8String,
              let codeC = (code as NSString).utf8String,
              let guidC = (deviceIdentifier as NSString).utf8String,
              let cacheDirC = (cacheDir as NSString).utf8String else {
            throw AppleAPIError.customError(code: -2600, message: "凭据转 C 字符串失败（含非法编码？）")
        }

        // cgo 生成头参数是 char*（UnsafeMutablePointer），utf8String 是 const char*
        //（UnsafePointer）——需 mutating 显式转换（cgo 指针参数惯例）.
        guard let resultPtr = EscapeAppStoreLogin(
            UnsafeMutablePointer(mutating: emailC),
            UnsafeMutablePointer(mutating: passwordC),
            UnsafeMutablePointer(mutating: codeC),
            UnsafeMutablePointer(mutating: guidC),
            UnsafeMutablePointer(mutating: cacheDirC)
        ) else {
            throw AppleAPIError.customError(code: -2601, message: "Go 登录返回空结果（cgo 异常）")
        }
        defer { SapFree(resultPtr) }

        let jsonString = String(cString: resultPtr)
        LoginLogger.shared.log("[GoAuth] Go 返回: \(jsonString.prefix(400))")

        guard let jsonData = jsonString.data(using: .utf8),
              let result = try? JSONDecoder().decode(LoginResult.self, from: jsonData) else {
            throw AppleAPIError.customError(code: -2602, message: "Go 登录返回无法解析: \(jsonString.prefix(200))")
        }

        // v0.3.263：逐请求诊断全量入日志（bag/sap-init/auth-attemptN 的 URL+guid、
        // 状态码、耗时）——<1s=边缘秒拒（服务器侧风控），数秒=后端拒（参数问题）.
        for diag in result.diagnostics ?? [] {
            LoginLogger.shared.log("[GoAuth][\(diag.step)] status=\(diag.status) \(diag.elapsedMs)ms \(diag.url.prefix(100))\(diag.detail.map { " | \($0.prefix(120))" } ?? "")")
        }

        if result.success, let account = result.account {
            // 成功：组装 AppStoreAccount。storefront 头（X-Set-Apple-Store-Front）
            // 值形如 "143441-1,29"——取首段纯 storeId（旧 Swift parseResponse 同款
            // 处理；AppStoreAccount convenience init 会校验 storeId 合法性）.
            let rawStore = account.storeFront ?? ""
            let store = rawStore.split(separator: "-").first.map(String.init)
                ?? (Configuration.storeId(for: Configuration.countryCode) ?? "143441")
            let cookies = (result.cookies ?? []).map { item in
                Cookie(
                    name: item.name,
                    value: item.value,
                    path: item.path ?? "/",
                    domain: item.domain,
                    httpOnly: false,
                    secure: true
                )
            }
            // Go 返回的 accountInfo 里姓名是合并串（"First Last"）；
            // AppStoreAccount 需要拆分（持久化与展示兼容）.
            let parts = (account.name ?? "").split(separator: " ", maxSplits: 1).map(String.init)
            // v0.3.304 修复：改用**不校验**的 memberwise init。
            //
            // 原实现走 `throws` 版 convenience init 并传 `firstName: nil, lastName: nil`，
            // 而该 init 内部是 `try firstName.get("unable to read firstName")` ——
            // nil 即抛错。真机实测报的就是这句：
            //     「登录失败: unable to read firstName」
            // 而且名字的拆分代码写在 init **之后**，永远执行不到（死代码）。
            // appleId / passwordToken / directoryServicesIdentifier 为 nil 时会抛同样的错，
            // 因此这里一并兜底（Go 侧字段缺失时不该让整个登录失败）。
            let final = AppStoreAccount(
                email: email,
                password: password,
                appleId: account.email ?? email,
                store: store,
                firstName: parts.first ?? "",
                lastName: parts.count > 1 ? parts[1] : "",
                passwordToken: account.passwordToken ?? "",
                directoryServicesIdentifier: account.directoryServicesID ?? "",
                cookie: cookies,
                pod: account.pod
            )
            LoginLogger.shared.log("[GoAuth] 登录成功: store=\(store), dsId=\(account.directoryServicesID ?? "?"), cookies=\(cookies.count)")
            return final
        }

        if result.authCodeRequired {
            // 与现有 2FA 弹窗的字符串判定兼容（调用方 contains 匹配）.
            throw AppleAPIError.customError(
                code: -2603,
                message: "Authentication requires verification code\n" +
                    "If no verification code prompted, try logging in at https://account.apple.com " +
                    "to trigger the alert and fill the code in the 2FA Code here."
            )
        }

        throw AppleAPIError.customError(
            code: -2604,
            message: result.error ?? "Go 登录失败（未知原因）"
        )
    }
}
