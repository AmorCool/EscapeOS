//
//  SSHServerService.swift
//  EscapeSpace
//
//  SSH 无线调试服务（v0.3.63）——路线 A：app 内嵌 Citadel（swift-nio-ssh）SSH 服务端。
//  用途：电脑 `ssh escape@<手机IP> -p 2222` 无线连接设备，执行内置诊断命令，
//  免去爱思导出日志的来回折腾。
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

final class SSHServerService: NSObject, ObservableObject {
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
    /// 便于随时无线连进来排查日志。
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
                await MainActor.run {
                    self.server = server
                    self.isRunning = true
                    self.beginBackgroundTaskIfNeeded()
                }
                print("[SSH] 服务已启动 port=\(port) user=\(username)")

                // 阻塞等待关闭（close 后自然返回）
                try await server.closeFuture.get()
                print("[SSH] 服务已关闭")
                await MainActor.run {
                    if self.server === server {
                        self.server = nil
                        self.isRunning = false
                        self.endBackgroundTaskIfNeeded()
                    }
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    self.lastError = "SSH 启动失败：\(error.localizedDescription)"
                    self.server = nil
                    self.isRunning = false
                }
            }
        }
    }

    func stop() {
        let server = self.server
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await server?.close()
            await MainActor.run {
                guard let self else { return }
                if self.server === server {
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
        case "modules":
            let mods = ModuleService.shared.listModules()
            guard !mods.isEmpty else { return "（无已安装模块）" }
            return mods.map { "\($0.id)  v\($0.version)  [\($0.name)]" }.joined(separator: "\n")
        case "logs":
            let n = Int(parts.count > 1 ? parts[1] : "30") ?? 30
            let all = LoginLogger.shared.fullLog().components(separatedBy: "\n")
            let tail = all.suffix(max(1, min(n, 200))).joined(separator: "\n")
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
            guard size <= 256 * 1024 else {
                return "文件过大（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))），仅支持 ≤256KB"
            }
            guard let s = try? String(contentsOf: target, encoding: .utf8) else { return "非 UTF-8 文本文件" }
            return s
        case "gotest":
            // 手动触发一次 Go runtime 初始化（返回 42 即成功）
            let box = GoCallBox { GoSelfTest() }
            box.run()
            return """
            GoSelfTest: 调用已发出
            结果: \(box.value.map { String($0) } ?? "（超时/未返回）")
            说明: 返回 42 = Go runtime 初始化成功
            """
        case "probe":
            // 进程内 Go 最小动作：写 <data>/probe.txt（不启服务）。
            // 数据目录以参数传入（Go env 快照问题，v0.3.78）——同时 setenv 作兜底。
            let probeDir = ModuleService.shared.dataURL(for: Self.firstBinaryModuleID())
            try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
            setenv("OPENLIST_DATA", probeDir.path, 1)
            // Go 导出签名是 char*（非 const），Swift 需显式转成可变 C 字符串指针
            let box = GoCallBox {
                probeDir.path.withCString { cstr in
                    OpenListProbe(UnsafeMutablePointer(mutating: cstr))
                }
            }
            box.run()
            return """
            OpenListProbe: 调用已发出
            结果: \(box.value.map { String($0) } ?? "（超时/未返回）")
            说明: >=0 = 进程内 Go 可写文件（写入字节数）；-1 = 写文件失败
            """
        case "startopenlist":
            // 远程触发 OpenListMain（长时间阻塞属正常），配合 trace 定位死在哪一步。
            // 与正式启动路径一致：设 OPENLIST_DATA + fd2 重定向到 data/go_stderr.log，
            // 这样 OpenList 内部 log.Fatalf 的临终信息才会落盘（v0.3.77）。
            let binID = Self.firstBinaryModuleID()
            let dataDir = ModuleService.shared.dataURL(for: binID)
            try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            setenv("OPENLIST_DATA", dataDir.path, 1)   // 兜底
            let goErr = dataDir.appendingPathComponent("go_stderr.log")
            let efd = open(goErr.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if efd >= 0 {
                dup2(efd, STDERR_FILENO)
                close(efd)
            }
            // 数据目录以参数传入（Go env 快照问题，v0.3.78）；char* 需显式转换
            let box = GoCallBox {
                dataDir.path.withCString { cstr in
                    OpenListMain(UnsafeMutablePointer(mutating: cstr))
                }
            }
            box.run(timeout: 3, keepAlive: true)
            return """
            OpenListMain: 已在 8MB 大栈后台线程调用
            结果: \(box.value.map { String($0) } ?? "（阻塞中＝服务在跑，属正常）")
            下一步: runlog 看 data/trace.txt 的打点（enter/args-set/error/panic）
            """
        case "mlog":
            // 读模块数据目录下的任意文件（OpenList 自己的 data/log/log.log 等）。
            // 注意：不能用通用 cat —— 它基于 FileManager.documentDirectory，而模块数据目录
            // 在 LC 下位于 NSHomeDirectory() 之下，两者不是同一棵树（v0.3.74 实锤）。
            let binID = Self.firstBinaryModuleID()
            let dataDir = ModuleService.shared.dataURL(for: binID)
            let name = parts.count > 1 ? parts[1] : "log/log.log"
            let n = parts.count > 2 ? (Int(parts[2]) ?? 60) : 60
            let target = dataDir.appendingPathComponent(name)
            guard let s = try? String(contentsOf: target, encoding: .utf8) else {
                // 文件不存在时列出数据目录，方便判断 OpenList 建了什么
                let fm = FileManager.default
                var listing = ["（无 \(name)；数据目录内容如下）"]
                if let items = try? fm.contentsOfDirectory(atPath: dataDir.path) {
                    for it in items.sorted() {
                        var isDir: ObjCBool = false
                        fm.fileExists(atPath: dataDir.appendingPathComponent(it).path, isDirectory: &isDir)
                        listing.append(isDir.boolValue ? "📁 \(it)/" : "📄 \(it)")
                    }
                }
                return listing.joined(separator: "\n")
            }
            let all = s.components(separatedBy: "\n").filter { !$0.isEmpty }
            return all.isEmpty ? "（空）" : all.suffix(min(max(n, 1), 400)).joined(separator: "\n")
        case "memtest":
            // 探测本进程内存天花板（判定是否 jetsam 硬杀）
            let mb = parts.count > 1 ? (Int(parts[1]) ?? 64) : 64
            let box = GoCallBox { OpenListMemTest(Int32(mb)) }
            box.run(timeout: 30)
            return """
            memtest: 申请 \(mb) MB
            结果: \(box.value.map { "成功申请 \($0) MB" } ?? "（未返回＝进程被杀，说明天花板低于 \(mb) MB）")
            """
        case "step1", "step2", "step3", "step4":
            // v0.3.79 二分诊断：逐步逼近 OpenListMain 的崩溃点。
            // 每步先写 stepN.begin、完成后写 stepN.done；哪一步让 App 崩，凶手就在该步新增语句里。
            let dir = ModuleService.shared.dataURL(for: Self.firstBinaryModuleID())
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let step = cmd
            let blocking = (step == "step4")
            let box = GoCallBox { () -> Int32 in
                dir.path.withCString { cstr in
                    let p = UnsafeMutablePointer(mutating: cstr)
                    switch step {
                    case "step1": return OpenListStep1(p)
                    case "step2": return OpenListStep2(p)
                    case "step3": return OpenListStep3(p)
                    default:      return OpenListStep4(p)
                    }
                }
            }
            box.run(timeout: blocking ? 4 : 3, keepAlive: blocking)
            return """
            \(step): 已调用（数据目录以参数传入）
            结果: \(box.value.map { String($0) } ?? (blocking ? "（阻塞中＝服务在跑，属正常）" : "（超时/未返回）"))
            下一步: runlog 看 \(step).begin / \(step).done 标记
            """
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
      modules         已安装模块列表
      logs [n]        登录日志末尾 n 行（默认 30）
      runlog [n]      二进制模块运行日志末尾 n 行（默认 40）
      step1..step4    OpenListMain 崩溃点二分诊断（逐步逼近）
      gotest          手动触发一次 Go runtime 初始化（诊断）
      probe           进程内 Go 写文件自检（写 <data>/probe.txt）
      startopenlist   远程调用 OpenListMain（配合 trace 定位）
      ls [路径]       浏览 Documents 目录（相对路径）
      cat <文件>      查看 Documents 内文本文件（≤256KB）
      ip              局域网 IP
      uptime          PiP 运行时长
      ping            连通性测试
      help            本帮助
    """
}

/// 在 8MB 大栈后台线程调用 Go 导出函数（带超时读取结果）
/// keepAlive=true 用于长期阻塞的调用（如 OpenListMain），故意不释放避免悬垂指针
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
