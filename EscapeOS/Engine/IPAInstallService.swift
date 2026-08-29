import Foundation
import Combine

/// IPA 侧载服务（汉化移植自 SideInstaller 的安装流程）。
///
/// 流程：登录 Apple ID（isideload，含 2FA）→ 签名 IPA（isideload
/// Sideloader::sign_app，自动注册设备/创建描述文件）→ 通过 LocalDevVPN 隧道
/// 用 AFC 上传签名后的 .app 到 /PublicStaging → installation_proxy 安装。
///
/// 与 SideInstaller 的差异（LC 兼容性）：
/// - 登录/签名走 isideload 的 sign-only 路径，纯网络 + 本地文件，不碰
///   本地网络权限与配对（原版在 LC guest 下卡在 LocalNetworkAuthorization）；
/// - 设备连接复用 EscapeSpace 既有隧道（配对文件 + LocalDevVPN），
///   签名所需的设备 UDID 直接从配对文件 plist 的 identifier 读取。
final class IPAInstallService: ObservableObject {

    static let shared = IPAInstallService()
    private init() {}

    // MARK: - 2FA 桥接

    /// 主线程回调：弹出 2FA 输入；reply(nil) 表示取消。
    var twoFactorPrompt: ((@escaping (String?) -> Void) -> Void)?

    private let twoFactorSem = DispatchSemaphore(value: 0)
    private var twoFactorResult: String?

    /// C 回调（isideload 需要 2FA 时调用）。阻塞等用户输入。
    /// 通过 `IPAInstallService.shared` 访问实例成员——编译器视为类型属性访问，
    /// 不捕获局部变量，可转换为 C 函数指针。
    private let twoFactorCallback: SITwoFactorCb = { _, outBuf, bufLen in
        IPAInstallService.shared.beginTwoFactorPrompt()
        // 最多等 5 分钟：用户不响应（或切走 App）时自动放弃，避免后台线程
        // 永久阻塞 —— 它占着串行登录队列，会让用户后续手动登录一起卡住。
        _ = IPAInstallService.shared.twoFactorSem.wait(timeout: .now() + 300)
        guard let code = IPAInstallService.shared.twoFactorResult, !code.isEmpty, bufLen > 1 else {
            return 0
        }
        IPAInstallService.shared.twoFactorResult = nil
        guard let outBuf else { return 0 }
        let bytes = Array(code.utf8.prefix(Int(bufLen) - 1))
        for (index, byte) in bytes.enumerated() {
            outBuf[index] = CChar(bitPattern: byte)
        }
        outBuf[bytes.count] = 0
        return 1
    }

    private func beginTwoFactorPrompt() {
        DispatchQueue.main.async {
            // 清掉上一轮可能残留的信号：否则本次 wait() 会立即被旧信号唤醒，
            // 拿着空的/旧的验证码往下走，表现就是"卡住后登录失败"。
            while self.twoFactorSem.wait(timeout: .now()) == .success { }
            self.twoFactorResult = nil
            // 优先用页面注入的 prompt（「IPA 侧载」页自己弹窗）。
            // 没有时（典型场景：App 启动的后台预热 warmUp，用户还没进过该页）
            // 走全局协调器，由 RootView 统一弹出输入框 —— 否则 2FA 请求会被
            // 静默丢弃：手机上弹了验证码，App 里却没地方输入，登录就此卡住。
            guard let handler = self.twoFactorPrompt else {
                TwoFactorPromptCoordinator.shared.requestCode(from: Self.twoFactorFeature) { code in
                    self.twoFactorResult = code
                    self.twoFactorSem.signal()
                }
                return
            }
            handler { code in
                self.twoFactorResult = code
                self.twoFactorSem.signal()
            }
        }
    }

    /// 全局 2FA 弹窗里显示的功能名。
    static let twoFactorFeature = "IPA 侧载"

    // MARK: - 会话

    /// isideload 的签名会话（登录成功后持有）。
    private var _session: OpaquePointer?
    @Published private(set) var isSignedIn = false
    @Published private(set) var teamSummary: String?

    /// 最近一次**完整登录**（`si_apple_signin`）拿到的 dsid 与
    /// `com.apple.gs.xcode.auth` token。由 isideload fork 暴露（v0.2.111），
    /// 调用方应持久化到 Keychain，下次用 `signInWithSession` 免登录恢复。
    /// 通过 token 恢复会话时这两个值不会更新（本来就已存在）。
    private(set) var lastSessionDSID: String?
    private(set) var lastSessionAuthToken: String?

    /// 登录/会话恢复的串行队列：Rust 调用是阻塞的，预热（app 启动后台）
    /// 与页面内自动登录可能并发，串行化保证同一时刻只有一个登录操作在跑，
    /// 避免两个调用同时读写 `_session` 造成竞态。
    private let authQueue = DispatchQueue(label: "com.ipaside.escapeos.auth")

    /// 「用 token 恢复会话」失败过一次（token 大概率已过期）。
    /// 为 true 时自动登录跳过免 2FA 恢复、直接走完整登录，避免每次进页面
    /// 都白等一次注定失败的恢复请求（实测单次失败恢复要 5~7 秒）。
    /// **持久化到 UserDefaults**（v0.2.105）：token 失效后 App 重启也不白等；
    /// 完整登录成功（token 刷新）时自动清零。
    private(set) var sessionRestoreFailed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.sessionRestoreFailedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.sessionRestoreFailedKey) }
    }

    /// App 启动后台预热（warmUp）正在执行中。页面自动登录据此**去重**，
    /// 避免 warmUp 与页面自动登录重复联网（v0.2.106 优化「每次几十秒」）。
    @Published private(set) var isWarmingUp = false

    private static let sessionRestoreFailedKey = "ipaSessionRestoreFailed"

    private(set) var session: OpaquePointer? {
        get { _session }
        set {
            _session = newValue
            isSignedIn = newValue != nil
        }
    }

    func signOut() {
        if let session {
            si_sign_session_free(session)
        }
        session = nil
        teamSummary = nil
    }

    deinit {
        if let _session {
            si_sign_session_free(_session)
        }
    }

    // MARK: - 路径

    /// EscapeSpace 的配对文件路径（与「应用」页 / JIT 共用）。
    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    /// isideload 的存储目录（anisette state 等，放 Library 下避免出现在
    /// 文件共享的 Documents）。
    private var storageDir: String {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("EscapeSpaceIsideload", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// **v0.2.117 根治「IPA 侧载登录后证书管理/增加内存限制全坏」**。
    ///
    /// 根因：Swift 认证（AnisetteProvider）与 isideload（Rust RemoteV3）各自随机
    /// 生成自己的 keychain_identifier —— 同一 Apple ID 从两套"虚拟机器"登录，
    /// Apple/Anisette 服务器会把它当两台设备，后续 Swift 侧的 Anisette 请求
    /// 被风控拒绝，表现为团队列表加载失败。
    ///
    /// 修复：把 Swift 侧的 identifier/adiPb 预写入 isideload 的
    /// `anisette_state`（plist 格式，isideload 读到已 provision 的 state 会
    /// **直接跳过 provisioning 复用**），让两套流程共用同一台"虚拟机器"。
    ///
    /// 此方法只在 Swift 侧已有 identifier+adiPb 时写入（不主动联网 provision）；
    /// 无值则跳过，Rust 侧自行 provision 兜底。
    func syncSharedAnisetteStateIfAvailable() {
        let provider = AnisetteProvider.shared
        let target = URL(fileURLWithPath: storageDir).appendingPathComponent("anisette_state")

        // v0.2.119：身份与票据必须**成对**才写。
        // 只写 identifier 不写 adi_pb 是"半截状态"—— Rust 侧 is_provisioned()
        // 判 false 会重新 provision，等于给了它一台"身份证号对不上"的机器。
        guard let identifier = provider.sharedMachineIdentifier,
              let adiPb = provider.sharedAdiPb else {
            // Swift 侧身份已重置（signOut / provision 失败 reset）→ 必须清掉
            // isideload 里的陈旧 state，让它下次全新 provision。
            // v0.2.118 及之前这里是直接 return，导致 Rust 一直沿用已被 Swift
            // 抛弃的旧设备身份 —— 两套实现从此分家，互相触发 Apple 风控。
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
                LoginLogger.shared.log("… Swift 侧无有效 Anisette 身份，已清除 IPA 侧载的陈旧机器标识（避免两套身份分裂）")
            } else {
                LoginLogger.shared.log("… Swift 侧暂无 Anisette 身份，IPA 侧载将自行 provision")
            }
            return
        }

        let dict: [String: Any] = ["keychain_identifier": identifier, "adi_pb": adiPb]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: target)
            let shortID = identifier.base64EncodedString().prefix(8)
            LoginLogger.shared.log("✓ 已同步 Anisette 机器标识给 IPA 侧载（id=\(shortID)… 服务器=\(provider.currentServer)）")
        } catch {
            LoginLogger.shared.log("⚠ 同步 Anisette 机器标识失败：\(error.localizedDescription)")
        }
    }

    /// 从配对文件 plist 读取设备 UDID（RPPairing 记录的 identifier）。
    private var deviceUDID: String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pairingPath)),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let udid = dict["identifier"] as? String, !udid.isEmpty else { return nil }
        return udid
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "IPAInstall", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message: String
        if let cString = ffiError.pointee.message {
            message = String(cString: cString)
        } else {
            message = ""
        }
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "IPAInstall", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    // MARK: - 登录（阻塞，后台线程调用）

    func signIn(appleID: String, password: String, anisetteURL: String) throws {
        try authQueue.sync {
            try performSignIn(appleID: appleID, password: password, anisetteURL: anisetteURL)
        }
    }

    /// v0.2.119 观测点：Rust 侧登录完成后读回 `anisette_state`，核对它是否真的
    /// 用了 Swift 共享过去的那台"虚拟机器"。
    ///
    /// 两套 identifier 不一致 = Apple 会当成两台设备登录同一账号 → 风控 →
    /// 团队列表加载失败。以前只能靠猜，现在日志会直接点名谁换了身份。
    private func verifySharedAnisetteState() {
        let target = URL(fileURLWithPath: storageDir).appendingPathComponent("anisette_state")
        guard let data = try? Data(contentsOf: target) else {
            LoginLogger.shared.log("⚠ 机器标识校验：IPA 侧载未落盘 anisette_state")
            return
        }
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            LoginLogger.shared.log("⚠ 机器标识校验：anisette_state 无法解析")
            return
        }
        let rustIDData: Data? = {
            if let d = dict["keychain_identifier"] as? Data { return d }
            // 极端兜底：Rust plist 序列化若落成字节数组，手动转一次。
            if let arr = dict["keychain_identifier"] as? [Any] {
                return Data(arr.compactMap { ($0 as? NSNumber)?.uint8Value })
            }
            return nil
        }()
        guard let rustID = rustIDData else {
            LoginLogger.shared.log("⚠ 机器标识校验：anisette_state 缺少 keychain_identifier（键：\(dict.keys.sorted().joined(separator: ","))）")
            return
        }
        guard let swiftID = AnisetteProvider.shared.sharedMachineIdentifier else {
            LoginLogger.shared.log("⚠ 机器标识校验：Swift 侧暂无 identifier（Rust=\(rustID.base64EncodedString().prefix(8))…）")
            return
        }
        if rustID == swiftID {
            LoginLogger.shared.log("✓ 机器标识校验一致（id=\(swiftID.base64EncodedString().prefix(8))…），两套流程同一台虚拟机器")
        } else {
            LoginLogger.shared.log("❌ 机器标识不一致！Swift=\(swiftID.base64EncodedString().prefix(8))… Rust=\(rustID.base64EncodedString().prefix(8))… —— 会被 Apple 当成两台设备")
        }
    }

    private func performSignIn(appleID: String, password: String, anisetteURL: String) throws {
        // v0.2.117：与 Swift 认证共用同一 Anisette 机器标识，避免 Apple 风控。
        syncSharedAnisetteStateIfAvailable()
        if let session {
            si_sign_session_free(session)
            self.session = nil
        }
        var newSession: OpaquePointer?
        var summary: UnsafeMutablePointer<CChar>?
        var dsidOut: UnsafeMutablePointer<CChar>?
        var authTokenOut: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let rc = appleID.withCString { id in
            password.withCString { pw in
                anisetteURL.withCString { ani in
                    "EscapeSpace".withCString { machine in
                        storageDir.withCString { dir in
                            si_apple_signin(id, pw, ani, machine, dir,
                                            twoFactorCallback, nil,
                                            &newSession, &summary,
                                            &dsidOut, &authTokenOut, &error)
                        }
                    }
                }
            }
        }
        defer {
            if let summary { si_string_free(summary) }
            if let dsidOut { si_string_free(dsidOut) }
            if let authTokenOut { si_string_free(authTokenOut) }
            if let error { si_string_free(error) }
        }
        if rc == 0, let newSession {
            session = newSession
            teamSummary = summary.map { String(cString: $0) }
            LoginLogger.shared.log("✓ IPA 侧载登录成功: \(teamSummary ?? "（无团队摘要）")")
            // v0.2.119：核对 Rust 是否真的复用了 Swift 共享的机器标识。
            verifySharedAnisetteState()
            // 取出 dsid + xcode.auth token（isideload fork 暴露），供调用方
            // 持久化后免登录恢复。
            lastSessionDSID = dsidOut.map { String(cString: $0) }
            lastSessionAuthToken = authTokenOut.map { String(cString: $0) }
            // 完整登录成功 → token 已刷新，恢复失败标志清除。
            sessionRestoreFailed = false
        } else {
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
            LoginLogger.shared.log("❌ IPA 侧载登录失败: \(msg)")
            throw makeError(msg)
        }
    }

    /// 用「更多 → 设置」已保存的 dsid + authToken 恢复签名会话
    /// （**免登录免 2FA**）。token 过期时抛错，调用方回退完整登录。
    func signInWithSession(email: String, dsid: String, authToken: String, anisetteURL: String) throws {
        try authQueue.sync {
            try performSignInWithSession(email: email, dsid: dsid, authToken: authToken, anisetteURL: anisetteURL)
        }
    }

    private func performSignInWithSession(email: String, dsid: String, authToken: String, anisetteURL: String) throws {
        // 已有会话（预热已完成）：直接复用，不再重建。
        if isSignedIn { return }
        // v0.2.117：与 Swift 认证共用同一 Anisette 机器标识。
        syncSharedAnisetteStateIfAvailable()
        var newSession: OpaquePointer?
        var summary: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let rc = email.withCString { e in
            dsid.withCString { d in
                authToken.withCString { t in
                    anisetteURL.withCString { a in
                        storageDir.withCString { dir in
                            "EscapeSpace".withCString { m in
                                si_signin_with_session(e, d, t, a, dir, m,
                                                       &newSession, &summary, &error)
                            }
                        }
                    }
                }
            }
        }
        defer {
            if let summary { si_string_free(summary) }
            if let error { si_string_free(error) }
        }
        if rc == 0, let newSession {
            session = newSession
            teamSummary = summary.map { String(cString: $0) }
            LoginLogger.shared.log("✓ IPA 侧载会话恢复成功: \(teamSummary ?? "（无团队摘要）")")
            // v0.2.119：核对 Rust 是否真的复用了 Swift 共享的机器标识。
            verifySharedAnisetteState()
            sessionRestoreFailed = false
        } else {
            // token 失效等恢复失败：标记，下次自动登录直接走完整登录。
            sessionRestoreFailed = true
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
            LoginLogger.shared.log("❌ IPA 侧载会话恢复失败: \(msg)")
            throw makeError(msg)
        }
    }

    // MARK: - 后台预热（app 启动时调用，免 2FA）

    /// 后台预热（app 启动时调用）。
    ///
    /// v0.2.108：两条路径并行提升体验——
    /// 1) 有 dsid + authToken（「设置」Apple ID 认证引擎登录过）→ 免 2FA 恢复会话；
    /// 2) 没有 token 但存了邮箱/密码（IPA 页登录过）→ 后台完整登录。
    ///    若使用 app 专用密码或已信任设备，可做到杀后台重开已登录；
    ///    否则 2FA 会静默失败，进入 IPA 页后自动登录会再试一次并弹验证码。
    /// 失败均静默，由页面内自动登录兜底。
    /// @MainActor：MemoryLimitSettings 是 MainActor 隔离类，读取其属性需在主线程。
    @MainActor
    func warmUp() {
        let settings = MemoryLimitSettings.shared
        guard settings.isLoggedIn, !settings.appleID.isEmpty else { return }
        guard !isSignedIn else { return }
        guard !isWarmingUp else { return }
        let id = settings.appleID
        let ani = settings.anisetteServer

        // 路径 A：有 token → 免 2FA 恢复。
        // v0.2.112：必须读 isideload 专用键（sideloadDSID/sideloadAuthToken）。
        // `dsid`/`authToken` 是 Swift 认证引擎的会话，两套 Anisette 机器标识不同，
        // 混用会导致 isideload 侧登录失败。
        if !sessionRestoreFailed,
           let dsid = settings.sideloadDSID, let authToken = settings.sideloadAuthToken,
           !dsid.isEmpty, !authToken.isEmpty {
            isWarmingUp = true
            Task.detached(priority: .utility) { [weak self] in
                defer { Task { @MainActor in self?.isWarmingUp = false } }
                guard let self else { return }
                do {
                    try self.signInWithSession(email: id, dsid: dsid, authToken: authToken, anisetteURL: ani)
                } catch {
                    // token 失效等：signInWithSession 内部已设 sessionRestoreFailed=true，
                    // 页面内自动登录会回退到完整登录。
                }
            }
            return
        }

        // 路径 B：无 token 但有密码 → 后台完整登录（2FA 弹窗未就绪，失败静默）。
        let pw = settings.password(forHistory: id) ?? ""
        guard !pw.isEmpty else { return }
        isWarmingUp = true
        Task.detached(priority: .utility) { [weak self] in
            defer { Task { @MainActor in self?.isWarmingUp = false } }
            guard let self else { return }
            do {
                try self.signIn(appleID: id, password: pw, anisetteURL: ani)
                // 成功后把凭据 + 本次登录的 dsid/authToken 一起持久化，
                // 下次 App 启动就能走路径 A 免登录恢复。
                let dsid = self.lastSessionDSID ?? ""
                let authToken = self.lastSessionAuthToken ?? ""
                await MainActor.run {
                    MemoryLimitSettings.shared.saveSessionCredentials(
                        email: id, password: pw, dsid: dsid, authToken: authToken)
                }
            } catch {
                // 静默：用户进入 IPA 页时页面内自动登录会再试并展示错误。
            }
        }
    }

    // MARK: - 签名（阻塞）

    /// 签名 IPA，返回签名后的 .app 包路径。
    func signIPA(ipaPath: String) throws -> String {
        guard let session else { throw makeError("尚未登录 Apple ID") }
        let udid = deviceUDID ?? ""
        var signed: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let rc = ipaPath.withCString { ipa in
            udid.withCString { u in
                "".withCString { name in
                    si_sign_ipa(session, ipa, u, name, &signed, &error)
                }
            }
        }
        defer {
            if let signed { si_string_free(signed) }
            if let error { si_string_free(error) }
        }
        if rc == 0, let signed {
            let path = String(cString: signed)
            guard !path.isEmpty else { throw makeError("签名返回空路径") }
            return path
        } else {
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
            throw makeError(msg)
        }
    }

    // MARK: - 安装（阻塞，进度回调）

    /// 通过 AFC 上传签名后的 .app 到 /PublicStaging 并用 installation_proxy 安装。
    /// `progress` 在主线程回调（0~1）。
    func install(signedAppPath: String, progress: ((Double) -> Void)? = nil) throws {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        var afc: OpaquePointer?
        if let ffiError = afc_client_connect_rsd(adapter, handshake, &afc) {
            throw error(from: ffiError, fallback: "连接 AFC 失败")
        }
        guard let afc else { throw makeError("AFC 客户端为空") }
        defer { afc_client_free(afc) }

        let name = (signedAppPath as NSString).lastPathComponent
        let remoteRoot = "/PublicStaging/\(name)"
        try uploadDirectory(afc, localDir: signedAppPath, remoteDir: remoteRoot)

        var ip: OpaquePointer?
        if let ffiError = installation_proxy_connect_rsd(adapter, handshake, &ip) {
            throw error(from: ffiError, fallback: "连接安装代理失败")
        }
        guard let ip else { throw makeError("安装代理客户端为空") }
        defer { installation_proxy_client_free(ip) }

        // PackageType: Developer —— 没有它 installd 不读内嵌描述文件，
        // 会在 VerifyingApplication 阶段报 0xe8008015。
        guard let options: plist_t = plist_new_dict() else {
            throw makeError("构建安装选项失败")
        }
        defer { plist_free(options) }
        if let packageType = plist_new_string("Developer") {
            plist_dict_set_item(options, "PackageType", packageType)
        }

        let progressCallback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { value, ctx in
            let progress = Double(value) / 100.0
            DispatchQueue.main.async {
                IPAInstallService.shared.installProgressHandler?(progress)
            }
        }
        installProgressHandler = progress

        let installErr = remoteRoot.withCString { p in
            installation_proxy_install_with_callback(ip, p, options, progressCallback, nil)
        }
        if let installErr {
            throw error(from: installErr, fallback: "安装失败")
        }
    }

    private var installProgressHandler: ((Double) -> Void)?

    /// 递归上传目录（映射读，避免大二进制撑爆内存）。
    private func uploadDirectory(_ afc: OpaquePointer, localDir: String, remoteDir: String) throws {
        _ = remoteDir.withCString { afc_make_directory(afc, $0) }
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: localDir)
        for entry in entries {
            let localPath = (localDir as NSString).appendingPathComponent(entry)
            let remotePath = "\(remoteDir)/\(entry)"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: localPath, isDirectory: &isDir)
            if isDir.boolValue {
                try uploadDirectory(afc, localDir: localPath, remoteDir: remotePath)
            } else {
                try uploadFile(afc, localPath: localPath, remotePath: remotePath)
            }
        }
    }

    private func uploadFile(_ afc: OpaquePointer, localPath: String, remotePath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: localPath), options: .mappedIfSafe)
        var file: OpaquePointer?
        if let ffiError = remotePath.withCString({ afc_file_open(afc, $0, AfcWrOnly, &file) }) {
            throw error(from: ffiError, fallback: "打开 \(remotePath) 失败")
        }
        guard let file else { throw makeError("AFC 文件句柄为空") }
        defer { _ = afc_file_close(file) }

        // 分块写，避免单次 FFI 调用撑爆内存。
        let chunk = 1 << 20
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = min(chunk, data.count - offset)
                if let ffiError = afc_file_write(file, base + offset, n) {
                    throw error(from: ffiError, fallback: "写入 \(remotePath) 失败")
                }
                offset += n
            }
        }
    }

    // MARK: - 隧道（与 JITEnableService 同源）

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    private func createTunnel() throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件。请先在「应用」页导入配对文件（需 LocalDevVPN + 开发者模式）。")
        }

        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw error(from: ffiError, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian

        let deviceIP = LocalDevVPN.targetIP
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)（请检查「设置 → 本地隧道」）")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = "EscapeSpaceIPAInstall".withCString { hostname in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hostname,
                            pairingFile,
                            nil,
                            nil,
                            &tunnel.adapter,
                            &tunnel.handshake
                        )
                    }
                }
            }
            if let ffiError {
                lastError = error(from: ffiError, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = makeError("创建开发者隧道失败")
            }
            if attempt < 2 {
                usleep(useconds_t(300_000 * (attempt + 1)))
            }
        }
        throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
    }
}
