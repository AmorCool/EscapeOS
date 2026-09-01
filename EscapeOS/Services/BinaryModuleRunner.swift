//
//  BinaryModuleRunner.swift
//  EscapeSpace
//
//  二进制模块运行器（v0.3.66）——模块规范 v1.1 "binary" 类型：
//   - 模块 zip 内带 iOS arm64 可执行文件（bin/<name>）
//   - 导入/启用/应用启动时自动后台拉起（autoStart），无需手动点击
//   - posix_spawn 启动、stdout/stderr 重定向到模块日志、kill 停止
//   - WebUI 模块（如 alist）暴露 http://127.0.0.1:<port> 入口
//
//  注意：原生机型受代码签名限制，需 ldid 伪签名的 arm64 二进制；
//  LC 环境下通常可直接运行。启动失败会以模块卡片错误形式反馈。
//

import Foundation
import UIKit

@MainActor
final class BinaryModuleRunner: ObservableObject {
    static let shared = BinaryModuleRunner()

    /// 运行中的二进制模块：模块 id → pid
    @Published private(set) var runningProcesses: [String: pid_t] = [:]
    /// 启动错误（模块 id → 信息）
    @Published private(set) var startErrors: [String: String] = [:]

    private init() {}

    // MARK: 生命周期

    /// 应用启动 / 模块导入 / 启用后调用：拉起所有声明 autoStart 的已启用二进制模块
    func autoStartAll() {
        for module in ModuleService.shared.listModules() {
            guard ModuleService.shared.isEnabled(id: module.id),
                  let bin = module.binary,
                  bin.autoStart == true else { continue }
            start(module: module)
        }
    }

    /// 启动模块二进制
    func start(module: EscapeModule) {
        guard let bin = module.binary else { return }
        guard runningProcesses[module.id] == nil else { return }

        do {
            let execURL = try prepareExecutable(module: module, relativePath: bin.executable)
            let workDir = module.installURL
            let logFile = workDir.appendingPathComponent("run.log")

            var args = bin.args ?? []
            // alist 惯例：--data 相对 cwd；原样透传，宿主不改写
            let pid = try posixSpawn(
                execURL: execURL,
                arguments: args,
                workingDirectory: workDir,
                logFile: logFile
            )
            runningProcesses[module.id] = pid
            startErrors[module.id] = nil
            print("[Binary][\(module.id)] 已启动 pid=\(pid) cmd=\(execURL.lastPathComponent) \(args.joined(separator: " "))")
        } catch {
            startErrors[module.id] = error.localizedDescription
            print("[Binary][\(module.id)] 启动失败: \(error.localizedDescription)")
        }
    }

    /// 停止模块二进制（SIGKILL）
    func stop(module: EscapeModule) {
        guard let pid = runningProcesses[module.id] else { return }
        kill(pid, SIGKILL)
        runningProcesses[module.id] = nil
        print("[Binary][\(module.id)] 已停止 pid=\(pid)")
    }

    /// 运行状态查询
    func isRunning(module: EscapeModule) -> Bool {
        guard let pid = runningProcesses[module.id] else { return false }
        return kill(pid, 0) == 0
    }

    /// WebUI 地址（binary.port + webPath）
    func webURL(for module: EscapeModule) -> URL? {
        guard let bin = module.binary, let port = bin.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(bin.webPath ?? "/")")
    }

    /// 打开 WebUI（浏览器）
    func openWebUI(module: EscapeModule) {
        guard let url = webURL(for: module) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: 内部

    /// 二进制就绪处理：拷贝到可写目录 + chmod 755
    /// （模块目录在 Documents 下本可写，直接 chmod 源文件即可；保底做一次拷贝语义）
    private func prepareExecutable(module: EscapeModule, relativePath: String) throws -> URL {
        let url = module.installURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BinaryModuleError.binaryMissing(relativePath)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    /// posix_spawn（stdout/stderr → 模块 run.log，stdin → /dev/null）
    private func posixSpawn(
        execURL: URL,
        arguments: [String],
        workingDirectory: URL,
        logFile: URL
    ) throws -> pid_t {
        var pid: pid_t = 0

        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // 独立进程组：kill 不误伤宿主
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var actionsMut = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actionsMut)
        defer { posix_spawn_file_actions_destroy(&actionsMut) }

        let logFD = open(logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard logFD >= 0 else {
            throw BinaryModuleError.spawnFailed("无法打开日志文件")
        }
        defer { close(logFD) }

        posix_spawn_file_actions_adddup2(&actionsMut, logFD, 1)
        posix_spawn_file_actions_adddup2(&actionsMut, logFD, 2)
        posix_spawn_file_actions_addopen(&actionsMut, 0, "/dev/null", O_RDONLY, 0)

        // chdir 需要 SPAWN_SETPGROUP 之外的动作：posix_spawn 无原生 chdir，
        // 用 args 里的相对路径（alist --data data 相对模块目录），进程 cwd 继承宿主。
        // 模块 args 全部使用绝对路径约定：导入时改写。此处直接绝对化传入。
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(execURL.path)
        ]
        for arg in arguments {
            argv.append(strdup(resolveArg(arg, moduleDir: workingDirectory)))
        }
        argv.append(nil)

        // 工作目录：把相对路径参数替换为模块目录绝对路径
        let rc = posix_spawn(&pid, execURL.path, &actionsMut, &attr, &argv, environ)
        for p in argv where p != nil { free(p) }

        guard rc == 0 else {
            throw BinaryModuleError.spawnFailed("posix_spawn 错误码 \(rc)")
        }
        return pid
    }

    /// 相对路径参数 → 模块目录绝对路径（alist --data data 场景）
    private func resolveArg(_ arg: String, moduleDir: URL) -> String {
        // 形如 "--data data" 的组合参数：最后一个 token 若是相对路径则拼接模块目录
        if arg.hasPrefix("--") {
            return arg
        }
        if arg.hasPrefix("/") || arg.hasPrefix("http") {
            return arg
        }
        return moduleDir.appendingPathComponent(arg).path
    }
}

enum BinaryModuleError: LocalizedError {
    case binaryMissing(String)
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let p): return "二进制文件缺失: \(p)"
        case .spawnFailed(let m): return "启动失败: \(m)"
        }
    }
}
