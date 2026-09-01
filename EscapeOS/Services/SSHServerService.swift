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

    private var server: Citadel.SSHServer?
    @MainActor private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static let defaultPort = 2222

    private override init() {
        let savedPort = UserDefaults.standard.integer(forKey: "ssh.port")
        port = savedPort > 0 ? savedPort : Self.defaultPort
        username = UserDefaults.standard.string(forKey: "ssh.username") ?? "escape"
        if let saved = UserDefaults.standard.string(forKey: "ssh.password"), !saved.isEmpty {
            password = saved
        } else {
            password = Self.generatePassword()
            UserDefaults.standard.set(password, forKey: "ssh.password")
        }
        lanIP = Self.detectLANIP() ?? "未连接 Wi-Fi"
    }

    // MARK: 凭据

    static func generatePassword() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in chars.randomElement()! })
    }

    func resetCredentials() {
        password = Self.generatePassword()
        UserDefaults.standard.set(password, forKey: "ssh.password")
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

    nonisolated static func detectLANIP() -> String? {
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
        outputHandler.stdoutPipe.fileHandleForWriting.write(Data(output.utf8))
        outputHandler.succeed(exitCode: 0)
        return NoopExecContext()
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
      ip              局域网 IP
      uptime          PiP 运行时长
      ping            连通性测试
      help            本帮助
    """
}

/// 空实现上下文（内置命令瞬时完成，无进程可终止）
final class NoopExecContext: ExecCommandContext {
    func terminate() async throws {}
    func inputClosed() async throws {}
}
