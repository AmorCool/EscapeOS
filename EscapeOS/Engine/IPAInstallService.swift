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
        IPAInstallService.shared.twoFactorSem.wait()
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
            guard let handler = self.twoFactorPrompt else {
                self.twoFactorResult = nil
                self.twoFactorSem.signal()
                return
            }
            handler { code in
                self.twoFactorResult = code
                self.twoFactorSem.signal()
            }
        }
    }

    // MARK: - 会话

    /// isideload 的签名会话（登录成功后持有）。
    private var _session: OpaquePointer?
    @Published private(set) var isSignedIn = false
    @Published private(set) var teamSummary: String?

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

    private func performSignIn(appleID: String, password: String, anisetteURL: String) throws {
        if let session {
            si_sign_session_free(session)
            self.session = nil
        }
        var newSession: OpaquePointer?
        var summary: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let rc = appleID.withCString { id in
            password.withCString { pw in
                anisetteURL.withCString { ani in
                    "EscapeSpace".withCString { machine in
                        storageDir.withCString { dir in
                            si_apple_signin(id, pw, ani, machine, dir,
                                            twoFactorCallback, nil,
                                            &newSession, &summary, &error)
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
            // 完整登录成功 → token 已刷新，恢复失败标志清除。
            sessionRestoreFailed = false
        } else {
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
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
            sessionRestoreFailed = false
        } else {
            // token 失效等恢复失败：标记，下次自动登录直接走完整登录。
            sessionRestoreFailed = true
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
            throw makeError(msg)
        }
    }

    // MARK: - 后台预热（app 启动时调用，免 2FA）

    /// 后台预热（app 启动时调用，免 2FA）。
    ///
    /// 只走 dsid + authToken 恢复会话；没有 token 时不在后台做完整登录，
    /// 因为完整登录现在走 `AppleAuthenticator`，需要 UI 弹 2FA。
    /// 没有 token 的情况由用户进入 IPA 页后的 `autoSignInWithSavedCredentials()` 处理。
    /// 失败静默，由页面内自动登录兜底。
    /// @MainActor：MemoryLimitSettings 是 MainActor 隔离类，读取其属性需在主线程。
    @MainActor
    func warmUp() {
        let settings = MemoryLimitSettings.shared
        guard settings.isLoggedIn, !settings.appleID.isEmpty else { return }
        guard !isSignedIn else { return }
        guard !isWarmingUp else { return }
        guard !sessionRestoreFailed,
              let dsid = settings.dsid, let authToken = settings.authToken,
              !dsid.isEmpty, !authToken.isEmpty else { return }
        let id = settings.appleID
        let ani = settings.anisetteServer
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
