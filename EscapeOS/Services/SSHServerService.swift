//
//  SSHServerService.swift
//  EscapeSpace
//
//  SSH 无线调试服务（v0.3.63）——路线 A：app 内嵌 Citadel（swift-nio-ssh）SSH 服务端.
//  用途：电脑 `ssh escape@<手机IP> -p 2222` 无线连接设备，执行内置诊断命令，
//  免去爱思导出日志的来回折腾.
//
//  安全模型：
//   - 仅监听局域网（本地网络权限保护，外网不可达）
//   - 单用户密码认证（随机生成、可重置），随时可关
//   - 受限 shell：不 spawn 任何进程，只应答内置诊断命令（status/logs/modules/ip/...）
//

import AVKit
import Citadel
import CryptoKit
import Foundation
import NIO
import NIOSSH
import UIKit

/// Swift 6：供同步函数阻塞等待 async 结果用的最小盒子（NSLock 保护，
/// 因此可安全标注 @unchecked Sendable —— 这是锁保护容器的标准用法，
/// 非「兜底标注」）.
private final class LockedResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func set(_ t: String) { lock.lock(); text = t; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return text }
}

/// `@unchecked Sendable`：可变状态（`server` 句柄与 `@Published` 状态）只在主线程写——
/// `start()` / `stop()` 的 `@Published` 写入都在 `await MainActor.run { … }` 里，调用点
/// （`EscapeSpaceApp.init` / 各 `View`）也都在主 actor；`server` 句柄仅在 start/stop
/// 各自的单个 detached 任务内写入（start 的 guard server == nil 检查在主线程先行，
/// stop 与 start 不会同时持有写窗口），非隔离的 `static execute` 只读共享状态做
/// 诊断输出，不做写。
final class SSHServerService: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = SSHServerService()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var port: Int
    /// 登录凭据（随机生成一次，可重置）
    @Published private(set) var username: String
    @Published private(set) var password: String
    /// 设备局域网 IP（en0）
    @Published private(set) var lanIP: String = "获取中…"
    /// 首次使用必须手动设置密码
    @Published private(set) var hasSetPassword = false

    private var server: Citadel.SSHServer?
    @MainActor private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static let defaultPort = 2222

    private override init() {
        // 存储属性必须全部先于 super.init() 初始化
        let savedPort = UserDefaults.standard.integer(forKey: "ssh.port")
        port = savedPort > 0 ? savedPort : Self.defaultPort
        username = UserDefaults.standard.string(forKey: "ssh.username") ?? "escape"
        if let saved = UserDefaults.standard.string(forKey: "ssh.password"), !saved.isEmpty {
            password = saved
        } else {
            // super.init 前不能读取 self（@Published 包装访问）——用局部变量中转
            let generated = Self.generatePassword()
            password = generated
            UserDefaults.standard.set(generated, forKey: "ssh.password")
        }
        lanIP = Self.detectLANIP() ?? "未连接 Wi-Fi"
        super.init()
        // super.init 之后才能读 self
        hasSetPassword = UserDefaults.standard.bool(forKey: "ssh.hasSetPassword")
    }

    // MARK: 凭据

    static func generatePassword() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in chars.randomElement()! })
    }

    func resetCredentials() {
        // 重置 = 回到「未设置密码」状态，强制下次首启重新设置
        password = Self.generatePassword()
        UserDefaults.standard.set(password, forKey: "ssh.password")
        UserDefaults.standard.set(false, forKey: "ssh.hasSetPassword")
        hasSetPassword = false
    }

    /// 用户手动设置密码（≥6 位），持久化并标记已设置
    func setPassword(_ newPassword: String) {
        let trimmed = newPassword.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 6 else {
            lastError = "密码至少 6 位"
            return
        }
        password = trimmed
        UserDefaults.standard.set(trimmed, forKey: "ssh.password")
        UserDefaults.standard.set(true, forKey: "ssh.hasSetPassword")
        hasSetPassword = true
        lastError = nil
    }

    /// 服务是否允许启动（必须已手动设置过密码）
    var canStart: Bool { hasSetPassword }

    /// Debug 模式：开启后每次启动 App 自动拉起 SSH 服务（无需手动点启动），
    /// 便于随时无线连进来排查日志.
    static let debugModeKey = "ssh.debugMode"
    var debugMode: Bool {
        get { UserDefaults.standard.bool(forKey: Self.debugModeKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.debugModeKey)
            objectWillChange.send()
            if newValue { autoStartIfNeeded() }
        }
    }

    /// Debug 模式开启时随 App 启动自动拉起（延迟 1.5s 避开启动高峰）
    func autoStartIfNeeded() {
        guard debugMode, canStart, !isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.start()
        }
    }

    func setPort(_ newPort: Int) {
        guard (1024...65535).contains(newPort), server == nil else { return }
        port = newPort
        UserDefaults.standard.set(newPort, forKey: "ssh.port")
    }

    // MARK: 启停

    func start() {
        guard server == nil else { return }
        lastError = nil
        lanIP = Self.detectLANIP() ?? lanIP

        // 主线程捕获凭据（避免跨隔离读 @Published）
        let port = self.port
        let username = self.username
        let password = self.password

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let hostKey = try Self.loadOrCreateHostKey()
                let auth = PasswordAuthDelegate(username: username, password: password)
                let exec = BuiltinCommandExecDelegate()

                let server = try await Citadel.SSHServer.host(
                    host: "0.0.0.0",
                    port: port,
                    hostKeys: [hostKey],
                    authenticationDelegate: auth
                )
                server.enableExec(withDelegate: exec)

                guard let self else { return }
                // Swift 6：server（非 Sendable）不再传进主 actor 闭包 —— 句柄直接写入
                // 本类存储（本类 @unchecked Sendable，句柄读写点仅 start/stop 两处），
                // 主 actor 只更新 @Published 状态（修 sending 'server'）.
                self.server = server
                await MainActor.run { [weak self] in
                    self?.isRunning = true
                    self?.beginBackgroundTaskIfNeeded()
                }
                print("[SSH] 服务已启动 port=\(port) user=\(username)")

                // 阻塞等待关闭（close 后自然返回）
                try await server.closeFuture.get()
                print("[SSH] 服务已关闭")
                let isCurrent = (self.server === server)
                await MainActor.run { [weak self] in
                    guard let self, isCurrent else { return }
                    self.server = nil
                    self.isRunning = false
                    self.endBackgroundTaskIfNeeded()
                }
            } catch {
                guard let self else { return }
                await MainActor.run { [weak self] in
                    self?.lastError = "SSH 启动失败：\(error.localizedDescription)"
                    self?.server = nil
                    self?.isRunning = false
                }
            }
        }
    }

    func stop() {
        let server = self.server
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await server?.close()
            guard let self else { return }
            // Swift 6：引用比较移出主 actor 闭包（修 sending 'server'）
            let isCurrent = (self.server === server)
            await MainActor.run {
                if isCurrent {
                    self.server = nil
                    self.isRunning = false
                }
                self.endBackgroundTaskIfNeeded()
            }
        }
    }

    @MainActor private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SSHServer") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundTaskIfNeeded()
            }
        }
    }

    @MainActor private func endBackgroundTaskIfNeeded() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: 主机密钥（持久化）

    private static func loadOrCreateHostKey() throws -> NIOSSHPrivateKey {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/ssh_host_ed25519.key")
        let key: Curve25519.Signing.PrivateKey
        if let data = try? Data(contentsOf: url),
           let saved = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            key = saved
        } else {
            key = Curve25519.Signing.PrivateKey()
            try? key.rawRepresentation.write(to: url)
        }
        return NIOSSHPrivateKey(ed25519Key: key)
    }

    // MARK: 局域网 IP

    static func detectLANIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let interface = p.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
            ptr = interface.ifa_next
        }
        return address
    }

    /// 重新探测局域网 IP（网络切换 / 回前台 / 用户手动刷新时调用）
    func refreshNetworkInfo() {
        let ip = Self.detectLANIP() ?? "未连接 Wi-Fi"
        DispatchQueue.main.async { self.lanIP = ip }
    }

    // MARK: 连接信息

    var connectHint: String {
        "ssh \(username)@\(lanIP) -p \(port)"
    }
}

// MARK: - 密码认证（Citadel README 示例同款结构）

final class PasswordAuthDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password]
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == username else {
            return responsePromise.succeed(.failure)
        }
        switch request.request {
        case .password(let credentials):
            let ok = credentials.password == password
            responsePromise.succeed(ok ? .success : .failure)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

// MARK: - 受限命令执行（不 spawn 任何进程，纯内置命令应答）

final class BuiltinCommandExecDelegate: ExecDelegate, @unchecked Sendable {
    func setEnvironmentValue(_ value: String, forKey key: String) async throws {
        // 忽略环境变量设置
    }

    func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext {
        let output = Self.execute(command)
        try outputHandler.stdoutPipe.fileHandleForWriting.write(Data(output.utf8))
        outputHandler.succeed(exitCode: 0)
        return NoopExecContext()
    }

    /// 第一个二进制模块的 id（SSH 诊断命令用）
    static func firstBinaryModuleID() -> String {
        ModuleService.shared.listModules().first(where: { $0.isBinaryModule })?.id ?? "com.escapeos.alist"
    }

    static func execute(_ raw: String) -> String {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        guard let cmd = parts.first else {
            return Self.helpText
        }
        switch cmd {
        case "help":
            return Self.helpText
        case "status":
            var lines = ["EscapeSpace 运行状态:"]
            lines.append("  PiP 保活: \(PiPKeepAliveService.shared.isPiPActive ? "运行中" : "未启动")")
            lines.append("  全局高刷: \(HighRefreshService.shared.isRunning ? "\(HighRefreshService.shared.maxFPS)Hz 强制" : "关闭")")
            lines.append("  模块数量: \(ModuleService.shared.listModules().count)")
            lines.append("  实测帧率: \(HighRefreshService.shared.measuredFPS) FPS")
            return lines.joined(separator: "\n")
        case "ddiprobe":
            // ▸ 只读诊断：判定设备上到底挂没挂 DDI（Developer Disk Image）。
            //
            // 为什么需要：主页两个内置模块（locache / wifirefresh）走
            // `app_service_connect_rsd` 时会出现 `ServiceNotFound`(21)。
            //
            // ⚠️ 关于 `ServiceNotFound` 的成因，本项目先后写过两版**都已作废**：
            //    ①「DDI 门控」（见 `CHANGELOG.md` `[0.3.462]`）；②「接错隧道」。
            //    **事实（用户实测 + PC 侧交叉验证）**：`ServiceNotFound`(21) 是**设备侧的服务状态
            //    问题**，不是本 App 的缺陷 —— 该服务偶尔不可用，**重启手机即恢复**；
            //    与 DDI、与「用哪条隧道」都无关（PC 侧标准工具 `pymobiledevice3` 拿到的 RSD
            //    服务表与我们**逐条一致**（64 条），调同一个服务**同样失败**）。**原理未知。**
            //    **本命令仍保留**：它回答的是「DDI 挂没挂」这个**独立**问题，
            //    只是**不再用来解释 `ServiceNotFound`**。
            // 本命令只回答一个问题：`image_mounter_copy_devices` 返回空还是非空。
            //
            // ⚠️ 只给 SSH 调试用。**不要挂到任何 UI 路径上** —— 它会真建 RSD 隧道，
            //    而且它开的服务连接**每次只允许一条**。
            // 安全约束全部落在 `DDIMountProbe` 头注释里（复用 AFC 串行队列 / 单连接 / 只读）。
            // 用法：ddiprobe   （同步阻塞执行，结束后直接读结果）
            return DDIMountProbe.runOnce()
        case "cdprobe":
            // ▸ 只读诊断：走「CoreDeviceProxy 隧道内的**第二个** RSD 握手」，
            // dump CoreDevice 服务表并端到端跑一次 app_service_list_processes。
            //
            // 为什么需要：主页两个内置模块（locache / wifirefresh）与「进程管理」走
            // `app_service_connect_rsd` 时会出现 `ServiceNotFound`(21)。
            //
            // ⚠️ 关于 `ServiceNotFound` 的成因，本项目先后写过两版**都已作废**
            //    （①「DDI 门控」；②「接错隧道」）。**事实（用户实测 + PC 侧交叉验证）**：
            //    `ServiceNotFound`(21) 是**设备侧的服务状态问题**，不是本 App 的缺陷 ——
            //    该服务偶尔不可用，**重启手机即恢复**；与 DDI、与「用哪条隧道」都无关
            //    （PC 侧标准工具 `pymobiledevice3` 拿到的 RSD 服务表与我们**逐条一致**，
            //    调同一个服务**同样失败**）。**原理未知。**
            // 仍然成立的一条：`RsdHandshake::connect` 是纯 HashMap 查表、查不到直接
            // 报错、**无回退** ⇒ 失败时重试 3 次毫无意义。
            //
            // 本命令因此只回答一个工程问题：CoreDeviceProxy 隧道内的「第二个 RSD 握手」
            // 这条路在本仓**能不能**走通（上游 `tools/src/app_service.rs:69-85`），
            // 并如实报告每一步的错误原文。
            //
            // ⚠️ 只给 SSH 调试用。**不要挂到任何 UI 路径上** —— 它会真建隧道 + 真开一条
            //    app_service 连接（RSD 隧道并发铁律；v0.3.419/420 事故见 `MY-FAULTS.md` 缺陷 17）。
            // 安全约束全部落在 `CDProbe` 头注释里（复用 AFC 串行队列 / 单连接 / 只读）。
            // 用法：cdprobe   （同步阻塞执行，结束后直接读结果）
            return CDProbe.runOnce()
        case "modules":
            let mods = ModuleService.shared.listModules()
            guard !mods.isEmpty else { return "（无已安装模块）" }
            return mods.map { "\($0.id)  v\($0.version)  [\($0.name)]" }.joined(separator: "\n")
        case "logs":
            let n = Int(parts.count > 1 ? parts[1] : "30") ?? 30
            let all = LoginLogger.shared.fullLog().components(separatedBy: "\n")
            let tail = all.suffix(max(1, min(n, 5000))).joined(separator: "\n")
            return tail.isEmpty ? "（登录日志为空）" : tail
        case "runlog":
            // 模块运行日志：run.log（宿主+子进程）+ data/stderr.log（进程内 Go）
            let n = Int(parts.count > 1 ? parts[1] : "40") ?? 40
            let mods = ModuleService.shared.listModules()
            guard let bin = mods.first(where: { $0.isBinaryModule }) else { return "（无二进制模块）" }
            var out: [String] = []
            let dir = ModuleService.shared.installURL(for: bin.id)
            let sources: [(String, URL)] = [
                ("run.log", dir.appendingPathComponent("run.log")),
                ("data/stderr.log", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("stderr.log")),
                // Go runtime 初始化阶段的 fatal/throw（fd 2 重定向产物，v0.3.74+）
                ("data/go_stderr.log", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("go_stderr.log")),
                // v0.3.76：Go 逐步打点（enter/args-set/error/panic）
                ("data/trace.txt", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("trace.txt")),
                ("data/probe.txt", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("probe.txt")),
                // v0.3.79 二分诊断标记
                ("data/step1.done", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("step1.done")),
                ("data/step2.done", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("step2.done")),
                ("data/step3.done", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("step3.done")),
                ("data/step4.begin", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("step4.begin")),
                ("data/step4.pre-execute", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("step4.pre-execute")),
                ("data/step4.done", ModuleService.shared.dataURL(for: bin.id).appendingPathComponent("step4.done")),
            ]
            for (label, path) in sources {
                guard let s = try? String(contentsOf: path, encoding: .utf8) else { continue }
                let all = s.components(separatedBy: "\n").filter { !$0.isEmpty }
                let keep = min(max(n, 1), 200)
                out.append("=== [\(bin.id)] \(label) 末尾 \(keep) 行 ===")
                // 空文件也显式标注（v0.3.75：空/非空本身是关键判据）
                out.append(all.isEmpty ? "（文件存在但为空）" : all.suffix(keep).joined(separator: "\n"))
            }
            return out.isEmpty ? "（暂无 \(bin.id) 运行日志）" : out.joined(separator: "\n")
        case "ls":
            // 浏览 Documents 目录（仅限 Documents 内，防路径越界）
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let rel = parts.dropFirst().joined(separator: " ")
            let target = rel.isEmpty ? docs : docs.appendingPathComponent(rel)
            let std = target.standardizedFileURL.path
            let docsStd = docs.standardizedFileURL.path
            guard std == docsStd || std.hasPrefix(docsStd + "/") else {
                return "❌ 路径越界（仅限 Documents 内）"
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: std, isDirectory: &isDir) else {
                return "不存在: \(rel)"
            }
            guard isDir.boolValue else { return "是文件，用 cat 查看: \(rel)" }
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: std) else {
                return "无法读取目录: \(rel)"
            }
            return items.sorted().map { name -> String in
                let p = (std as NSString).appendingPathComponent(name)
                var d: ObjCBool = false
                FileManager.default.fileExists(atPath: p, isDirectory: &d)
                if d.boolValue { return "📁 \(name)/" }
                var sz: UInt64 = 0
                if let attr = try? FileManager.default.attributesOfItem(atPath: p),
                   let s = attr[.size] as? UInt64 { sz = s }
                return "📄 \(name)  (\(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file)))"
            }.joined(separator: "\n")
        case "cat":
            // 查看 Documents 内文本文件（限 256KB）
            guard parts.count > 1 else { return "用法: cat <Documents 内相对路径>" }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let rel = parts.dropFirst().joined(separator: " ")
            let target = docs.appendingPathComponent(rel).standardizedFileURL
            let docsStd = docs.standardizedFileURL.path
            guard target.path.hasPrefix(docsStd + "/") else { return "❌ 路径越界（仅限 Documents 内）" }
            guard let attr = try? FileManager.default.attributesOfItem(atPath: target.path),
                  let size = attr[.size] as? UInt64 else { return "不存在: \(rel)" }
            // v0.3.434：上限改为**用户可配置**（「更多 → 设置 → 日志」，默认 1024KB，填 0 = 无限制）
            let catLimit = LogLimitSettings.catLimitBytes
            if catLimit < Int.max {                 // 无限制 → 跳过检查
                guard size <= UInt64(catLimit) else {
                    return "文件过大（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))），"
                        + "当前上限 \(catLimit / 1024)KB（可在「更多 → 设置 → 日志」调整；填 0 = 无限制）"
                }
            }
            guard let s = try? String(contentsOf: target, encoding: .utf8) else { return "非 UTF-8 文本文件" }
            return s
                case "invoke":
            // v0.3.112 通用符号调用：任何二进制模块的任何导出符号都能调.
            // 此前硬编码的专用命令（模块名即符号名）已删除——那些是「模块的数据」，
            // 不该出现在引擎代码里.用法：invoke <符号名>
            guard parts.count >= 2 else {
                return "用法: invoke <符号名>   —— 调用当前二进制模块的导出符号（数据目录作参数传入）"
            }
            let symName = parts[1]

            let binID = Self.firstBinaryModuleID()
            let moduleDir = ModuleService.shared.installURL(for: binID)
            let dataDir = ModuleService.shared.dataURL(for: binID)
            try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            setenv("MODULE_DATA_DIR", dataDir.path, 1)   // 通用兜底：数据目录传给模块

            guard let sym = BinaryModuleRunner.resolveBinaryModuleSymbol(symName, moduleDir: moduleDir, moduleId: binID) else {
                return "❌ 符号未找到: \(symName)\n"
                     + "   模块: \(binID)\n"
                     + "   可能原因：dylib 加载失败（dyld 库校验拒绝 ad-hoc 签名）或符号未导出\n"
                     + "   详情: runlog 25"
            }

            // v0.3.120：与 start 路径对齐——stderr 重定向 + 崩溃探针（硬故障落盘）
            let goErr = dataDir.appendingPathComponent("go_stderr.log")
            let efd = open(goErr.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if efd >= 0 {
                dup2(efd, STDERR_FILENO)
                close(efd)
            }
            uloader_install_crash_probe(STDERR_FILENO)
            typealias DirFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32
            let fn = unsafeBitCast(sym, to: DirFn.self)
            let bytes = sym.assumingMemoryBound(to: UInt8.self)
            let codeHex = (0..<16).map { String(format: "%02x", bytes[$0]) }.joined(separator: " ")
            let box = GoCallBox {
                dataDir.path.withCString { cstr in fn(UnsafeMutablePointer(mutating: cstr)) }
            }
            box.run(timeout: 3, keepAlive: true)
            let resultText = box.value.map { String($0) } ?? "（阻塞中＝服务在跑，属正常）"
            return "\(symName): 已调用（数据目录以参数传入）\n入口=\(sym) 前16字节: \(codeHex)\n结果: \(resultText)\n下一步: runlog 查看模块日志；若闪退见 go_stderr.log 的 [uloader-crash] 行"

        case "store":
            // v0.3.341：远程触发 App Store 下载（诊断/自测用）。
            // 用法：store get <trackId> [email]   —— 不传 email 用当前下载账号。
            // 走与界面「获取」完全相同的路径（IPADownloadCenter.startWithAppleID），
            // 结果全部落在商店日志里，可用 `logs` 直接读回。
            guard parts.count >= 3, parts[1] == "get", let trackId = Int64(parts[2]) else {
                return "用法: store get <trackId> [email]"
            }
            let explicitEmail = parts.count >= 4 ? parts[3] : nil
            Task { @MainActor in
                do {
                    guard let item = try await AppStoreService.lookup(id: "\(trackId)") else {
                        LoginLogger.shared.log("[SSH] 未找到应用 trackId=\(trackId)", category: .appStore)
                        return
                    }
                    let email = explicitEmail ?? AppStoreDownloadStore.shared.selectedEmail ?? ""
                    guard !email.isEmpty else {
                        LoginLogger.shared.log("[SSH] 没有已登录的下载账号，无法触发", category: .appStore)
                        return
                    }
                    LoginLogger.shared.log("[SSH] 触发下载：\(item.name)（\(item.bundleId ?? "-")）trackId=\(trackId) 账号=\(email)",
                                           category: .appStore)
                    _ = IPADownloadCenter.shared.startWithAppleID(item: item, email: email)
                } catch {
                    LoginLogger.shared.log("[SSH] 触发下载失败：\(error.localizedDescription)", category: .appStore)
                }
            }
            return "已触发下载 trackId=\(trackId)；用 logs 200 查看过程"

        case "devcert":
            // v0.3.130：远程触发开发证书创建（诊断/自测用）.
            // 流程：生成密钥+CSR → 提交 Apple →（7460 自动吊销重试）→ 轮询取证书.
            // execute 是同步函数 → 信号量等 Task 完成（整流程最多 ~40 秒）.
            // Swift 6：Task（@Sendable）不能捕获可变局部变量 —— 结果装进锁保护的
            // 盒子（sem.wait/signal 已建立 happens-before，锁只满足类型系统）.
            let sem = DispatchSemaphore(value: 0)
            let devcertBox = LockedResultBox()
            Task {
                do {
                    try await DeveloperCertStore.shared.createCertificateWithStoredAccount()
                    devcertBox.set("✓ 开发证书创建成功（已存 DeveloperCert/，原生模块将用真证书签名加载）")
                } catch {
                    devcertBox.set("❌ 开发证书创建失败: \((error as NSError).localizedDescription)")
                }
                sem.signal()
            }
            sem.wait()
            return "devcert: \(devcertBox.get())\n详情: logs"

        case "mlog":
            // 读模块数据目录下的任意文件.
            // 注意：不能用通用 cat —— 它基于 FileManager.documentDirectory，而模块数据目录
            // 在 LC 下位于 NSHomeDirectory() 之下，两者不是同一棵树（v0.3.74 实锤）.
            let binID = Self.firstBinaryModuleID()
            let dataDir = ModuleService.shared.dataURL(for: binID)
            let name = parts.count > 1 ? parts[1] : "log/log.log"
            let n = parts.count > 2 ? (Int(parts[2]) ?? 60) : 60
            let target = dataDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
                // 目录 → 列出内容（如 mlog temp 查看 stage 标记文件）
                let fm = FileManager.default
                var listing = ["（目录 \(name)/ 内容如下）"]
                if let items = try? fm.contentsOfDirectory(atPath: target.path) {
                    for it in items.sorted() {
                        var sub: ObjCBool = false
                        fm.fileExists(atPath: target.appendingPathComponent(it).path, isDirectory: &sub)
                        let size = (try? fm.attributesOfItem(atPath: target.appendingPathComponent(it).path)[.size] as? Int) ?? nil
                        listing.append(sub.boolValue ? "📁 \(it)/" : "📄 \(it)\((size.map { " (\($0)B)" }) ?? "")")
                    }
                }
                return listing.joined(separator: "\n")
            }
            guard let s = try? String(contentsOf: target, encoding: .utf8) else {
                // 文件不存在时列出数据目录，方便判断模块建了什么
                let fm = FileManager.default
                var listing = ["（无 \(name)；数据目录内容如下）"]
                if let items = try? fm.contentsOfDirectory(atPath: dataDir.path) {
                    for it in items.sorted() {
                        var sub: ObjCBool = false
                        fm.fileExists(atPath: dataDir.appendingPathComponent(it).path, isDirectory: &sub)
                        listing.append(sub.boolValue ? "📁 \(it)/" : "📄 \(it)")
                    }
                }
                return listing.joined(separator: "\n")
            }
            let all = s.components(separatedBy: "\n").filter { !$0.isEmpty }
            return all.isEmpty ? "（空）" : all.suffix(min(max(n, 1), 400)).joined(separator: "\n")
        case "caplog":
            // 宿主能力调用日志（所有模块共用一份）—— 排障「模块为什么没生效」的第一现场.
            //
            // 由宿主在**每次**能力调用后追加（见 HostCapabilityService.appendCallLog）：
            // 原生界面的模块（视图编译进宿主）没有自己的日志通道，dylib 模块的 data/
            // 也看不到「宿主到底收到什么、返回什么」，所以统一记在宿主侧 ——
            // 这样任何模块形态都查得到，而模块本身一行代码都不用改.
            let n = Int(parts.count > 1 ? parts[1] : "60") ?? 60
            let url = HostCapabilityService.callLogURL
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return "（暂无能力调用日志）\n路径: \(url.path)\n（第一次调用宿主能力后才会创建）"
            }
            let all = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard !all.isEmpty else { return "（能力调用日志为空）\n路径: \(url.path)" }
            let keep = min(max(n, 1), 2000)
            return "=== 宿主能力调用日志（末尾 \(keep) 行）===\n路径: \(url.path)\n"
                + all.suffix(keep).joined(separator: "\n")
        case "modls":
            // 列**任意模块**的数据目录（通用版 mlog —— mlog 只看二进制模块）
            let id = parts.count > 1 ? parts[1] : Self.firstBinaryModuleID()
            let dir = ModuleService.shared.dataURL(for: id)
            var lines = ["=== \(id) 数据目录 ===", dir.path]
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
                lines.append("（目录不存在或不可读 —— 该模块可能还没写过数据）")
                return lines.joined(separator: "\n")
            }
            if items.isEmpty { lines.append("（空目录）") }
            for it in items.sorted() {
                let full = dir.appendingPathComponent(it)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
                let size = (try? FileManager.default.attributesOfItem(atPath: full.path)[.size] as? Int) ?? nil
                lines.append(isDir.boolValue ? "📁 \(it)/" : "📄 \(it)\((size.map { " (\($0)B)" }) ?? "")")
            }
            return lines.joined(separator: "\n")
        case "modcat":
            // 读**任意模块**数据目录下的文本文件（通用版 mlog）
            // 用法: modcat <模块id> <相对路径> [n]
            guard parts.count > 2 else { return "用法: modcat <模块id> <相对路径> [n]" }
            let id = parts[1]
            let rel = parts[2]
            let n = parts.count > 3 ? (Int(parts[3]) ?? 80) : 80
            let dir = ModuleService.shared.dataURL(for: id)
            let target = dir.appendingPathComponent(rel)
            // 防路径越界：标准化后必须仍在模块数据目录内
            guard target.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path) else {
                return "拒绝：路径越出模块数据目录"
            }
            guard let text = try? String(contentsOf: target, encoding: .utf8) else {
                return "（读不到 \(id)/\(rel)；先跑 modls \(id) 看该模块有什么）"
            }
            let all = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            return all.isEmpty ? "（文件存在但为空）"
                : all.suffix(min(max(n, 1), 2000)).joined(separator: "\n")
        case "cap":
            // 直接调一次宿主能力（排障用）：`cap <能力名> [JSON]`
            //
            // 与模块走的是**同一个** `HostCapabilityService.call`（所以也会进 `caplog`）——
            // 有了它就能在 SSH 里逐个能力试，不用装模块、不用点界面。
            //
            // 例：cap host.version
            //     cap afc.list '{"path":"/DCIM"}'
            //     cap proc.list
            //
            // ⚠️ 同步阻塞：有些能力会真的连设备，一次可能十几秒。
            guard parts.count > 1 else {
                return "用法: cap <能力名> [JSON]\n"
                    + "例: cap host.version\n"
                    + "    cap afc.list '{\"path\":\"/DCIM\"}'\n"
                    + "能力清单: " + HostCapabilityService.capabilityList.joined(separator: ", ")
            }
            let capability = parts[1]
            let argText = parts.dropFirst(2).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let (rc, result) = HostCapabilityService.call(capability: capability,
                                                          jsonArgs: argText.isEmpty ? "{}" : argText)
            return "rc=\(rc)\n\(result)"
        case "luaeval", "luaexec":
            // v0.3.95：Lua 模块宿主（Rust+mlua，编进 App）.luaeval=表达式求值，luaexec=语句块.
            let code = String(raw.dropFirst(cmd.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { return "用法: \(cmd) <lua 表达式/代码>" }
            let outPath = ModuleService.shared.dataURL(for: Self.firstBinaryModuleID())
                .appendingPathComponent("lua_out.txt")
            try? FileManager.default.createDirectory(
                at: outPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            WiFiPowerBridge.shared.ensureRegistered()   // 注册隧道 wifi handler（幂等）
            let isEval = (cmd == "luaeval")
            let box = GoCallBox {
                code.withCString { c in
                    outPath.path.withCString { o in
                        let cp = UnsafeMutablePointer(mutating: c)
                        let op = UnsafeMutablePointer(mutating: o)
                        return isEval ? lua_host_eval(cp, op) : lua_host_exec(cp, op)
                    }
                }
            }
            box.run(timeout: 10)
            let ret = box.value.map { String($0) } ?? "超时"
            let result = (try? String(contentsOf: outPath, encoding: .utf8)) ?? "（无输出）"
            return "Lua 返回码: \(ret)\n结果: \(result)"
        case "ip":
            return SSHServerService.detectLANIP() ?? "未获取到局域网 IP"
        case "ping":
            return "pong"
        case "uptime":
            if let startedAt = PiPKeepAliveService.shared.startedAt {
                let s = Int(Date().timeIntervalSince(startedAt))
                return String(format: "PiP 运行时长: %02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            }
            return "PiP 未运行"
        case "clear":
            return ""
        default:
            return "未知命令: \(cmd)\n输入 help 查看可用命令"
        }
    }

    static let helpText = """
    EscapeSpace SSH 调试 · 可用命令:
      status          运行状态总览
      ddiprobe        只读诊断：查设备是否已挂 DDI（结果 → LoginLogs/ddi_probe.txt）
      cdprobe         只读诊断：CoreDeviceProxy 隧道内第二个 RSD 握手 + app_service 端到端（结果 → LoginLogs/cd_probe.txt）
      modules         已安装模块列表
      logs [n]        登录日志末尾 n 行（默认 30，最多 5000）
      runlog [n]      二进制模块运行日志末尾 n 行（默认 40）
      caplog [n]      **宿主能力调用日志**末尾 n 行（默认 60）—— 任何模块（原生界面 / dylib / lua）调宿主能力的入参与返回原文，排障「模块为什么没生效」看这个
      cap <能力名> [JSON]   直接调一次宿主能力（与模块同一个分发器，也会进 caplog）。例: cap host.version / cap afc.list '{"path":"/DCIM"}'
      modls [模块id]  列任意模块的数据目录（省略 id = 第一个二进制模块）
      modcat <模块id> <相对路径> [n]   读任意模块数据目录下的文本文件（默认 80 行）
      invoke <符号>  调用当前二进制模块的导出符号（通用，取代旧专用命令）
      store get <trackId> [email]   触发一次 App Store 下载（与界面「获取」同一条路径）
      devcert        创建开发证书（用已登录 Apple ID；原生模块签名用）
      ls [路径]       浏览 Documents 目录（相对路径）
      cat <文件>      查看 Documents 内文本文件（≤8MB）
      ip              局域网 IP
      uptime          PiP 运行时长
      ping            连通性测试
      help            本帮助
    """
}

/// 在 8MB 大栈后台线程调用 Go 导出函数（带超时读取结果）
/// keepAlive=true 用于长期阻塞的调用（如模块入口函数），故意不释放避免悬垂指针
final class GoCallBox {
    private let lock = NSLock()
    private var _value: Int32?
    private let body: () -> Int32
    var value: Int32? { lock.lock(); defer { lock.unlock() }; return _value }

    init(_ body: @escaping () -> Int32) { self.body = body }

    func run(timeout: TimeInterval = 3, keepAlive: Bool = false) {
        var attr = pthread_attr_t()
        guard pthread_attr_init(&attr) == 0 else { return }
        pthread_attr_setstacksize(&attr, 8 * 1024 * 1024)
        var tid: pthread_t?
        let ctx = keepAlive ? Unmanaged.passRetained(self).toOpaque()
                            : Unmanaged.passUnretained(self).toOpaque()
        pthread_create(&tid, &attr, goCallEntry, ctx)
        pthread_attr_destroy(&attr)
        let deadline = Date().addingTimeInterval(timeout)
        while value == nil, Date() < deadline { usleep(100_000) }
    }

    fileprivate func set(_ v: Int32) { lock.lock(); _value = v; lock.unlock() }
    fileprivate func call() -> Int32 { body() }
}

private let goCallEntry: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { ctx in
    let box = Unmanaged<GoCallBox>.fromOpaque(ctx).takeUnretainedValue()
    box.set(box.call())
    return nil
}

/// 空实现上下文（内置命令瞬时完成，无进程可终止）
final class NoopExecContext: ExecCommandContext {
    func terminate() async throws {}
    func inputClosed() async throws {}
}
