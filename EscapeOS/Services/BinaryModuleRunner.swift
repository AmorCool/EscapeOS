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

    /// 运行中的二进制模块：模块 id → pid（-2 = 进程内 dylib 模式）
    @Published private(set) var runningProcesses: [String: pid_t] = [:]
    /// 启动错误（模块 id → 信息）
    @Published private(set) var startErrors: [String: String] = [:]
    /// 进程内 dylib 模式的模块 id（无独立 pid，随宿主退出）
    @Published private(set) var inProcessModules: Set<String> = []

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
    /// 模块自带 bin/*.dylib 时直接进程内 dlopen（侧载 LC 环境 posix_spawn 必被
    /// AMFI 拒 EPERM，平台级限制；进程内加载机制同 LC 加载 tweak，不受限）。
    /// 无 dylib 时走 posix_spawn（TrollStore/平台化环境仍可用），EPERM 时再回退 dylib。
    func start(module: EscapeModule) {
        guard let bin = module.binary else { return }
        guard runningProcesses[module.id] == nil else { return }

        let workDir = module.installURL
        let logFile = workDir.appendingPathComponent("run.log")

        // 1) 进程内 dylib 优先
        if let dylibURL = findDylib(moduleDir: workDir) {
            do {
                try startInProcess(module: module, dylibURL: dylibURL, logFile: logFile)
                inProcessModules.insert(module.id)
                runningProcesses[module.id] = -2
                startErrors[module.id] = nil
                appendLog(logFile, "[host] 进程内加载 \(dylibURL.lastPathComponent) 成功（随宿主退出）")
                print("[Binary][\(module.id)] 已进程内启动 dylib=\(dylibURL.lastPathComponent)")
                return
            } catch {
                appendLog(logFile, "[host] 进程内加载失败: \(error.localizedDescription) → 尝试独立进程")
                startErrors[module.id] = nil
            }
        }

        // 2) 独立进程 spawn（无 dylib 或 dylib 加载失败时）
        do {
            let execURL = try prepareExecutable(module: module, relativePath: bin.executable)
            var args = bin.args ?? []
            // alist 惯例：--data 相对 cwd；原样透传，宿主不改写
            do {
                let pid = try posixSpawn(
                    execURL: execURL,
                    arguments: args,
                    workingDirectory: workDir,
                    logFile: logFile
                )
                runningProcesses[module.id] = pid
                inProcessModules.remove(module.id)
                startErrors[module.id] = nil
                print("[Binary][\(module.id)] 已启动 pid=\(pid) cmd=\(execURL.lastPathComponent) \(args.joined(separator: " "))")
                appendLog(logFile, "[host] posix_spawn 成功 pid=\(pid)")
            } catch BinaryModuleError.spawnEPERM(let msg) {
                // AMFI 拒绝 → 进程内 dylib 回退
                appendLog(logFile, "[host] \(msg)")
                guard let dylibURL = findDylib(moduleDir: workDir) else {
                    startErrors[module.id] = BinaryModuleError.spawnEPERM(msg).localizedDescription
                        + "；模块未携带 dylib，无法进程内回退"
                    appendLog(logFile, "[host] 无 bin/*.dylib，回退失败")
                    print("[Binary][\(module.id)] EPERM 且无 dylib 可回退")
                    return
                }
                appendLog(logFile, "[host] EPERM → 进程内加载 \(dylibURL.lastPathComponent)")
                try startInProcess(module: module, dylibURL: dylibURL, logFile: logFile)
                inProcessModules.insert(module.id)
                runningProcesses[module.id] = -2
                startErrors[module.id] = nil
                print("[Binary][\(module.id)] 已进程内启动 dylib=\(dylibURL.lastPathComponent)")
            }
        } catch {
            startErrors[module.id] = error.localizedDescription
            print("[Binary][\(module.id)] 启动失败: \(error.localizedDescription)")
        }
    }

    /// 停止模块二进制（SIGKILL；进程内 dylib 模式随宿主退出，无法单独停止）
    func stop(module: EscapeModule) {
        guard let pid = runningProcesses[module.id] else { return }
        guard pid > 0 else {
            print("[Binary][\(module.id)] 进程内 dylib 模式：随宿主退出，不支持单独停止")
            return
        }
        kill(pid, SIGKILL)
        runningProcesses[module.id] = nil
        print("[Binary][\(module.id)] 已停止 pid=\(pid)")
    }

    /// 运行状态查询
    func isRunning(module: EscapeModule) -> Bool {
        if inProcessModules.contains(module.id) { return true }
        guard let pid = runningProcesses[module.id], pid > 0 else { return false }
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

        // iOS SDK 上 posix_spawnattr_t()/posix_spawn_file_actions_t() 默认构造器
        // 不可用（missing argument for parameter #1）——用指针分配 + init 零填充
        let attrPtr = UnsafeMutablePointer<posix_spawnattr_t?>.allocate(capacity: 1)
        defer { attrPtr.deallocate() }
        posix_spawnattr_init(attrPtr)

        let actionsPtr = UnsafeMutablePointer<posix_spawn_file_actions_t?>.allocate(capacity: 1)
        posix_spawn_file_actions_init(actionsPtr)
        defer {
            posix_spawn_file_actions_destroy(actionsPtr)
            actionsPtr.deallocate()
        }

        let logFD = open(logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard logFD >= 0 else {
            throw BinaryModuleError.spawnFailed("无法打开日志文件")
        }
        defer { close(logFD) }

        posix_spawn_file_actions_adddup2(actionsPtr, logFD, 1)
        posix_spawn_file_actions_adddup2(actionsPtr, logFD, 2)
        posix_spawn_file_actions_addopen(actionsPtr, 0, "/dev/null", O_RDONLY, mode_t(0))

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
        let rc = posix_spawn(&pid, execURL.path, actionsPtr, attrPtr, &argv, environ)
        for p in argv where p != nil { free(p) }

        guard rc == 0 else {
            let reason = String(cString: strerror(rc))
            if rc == 1 {
                // EPERM：AMFI 拒绝执行（侧载非平台化环境的平台限制），调用方回退 dylib
                throw BinaryModuleError.spawnEPERM("posix_spawn 错误码 1 (EPERM)：系统拒绝执行第三方二进制")
            }
            throw BinaryModuleError.spawnFailed("posix_spawn 错误码 \(rc)（\(reason)）")
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

    // MARK: 进程内 dylib 回退（AMFI EPERM 场景）

    /// 查找模块 bin/ 下第一个 .dylib（模块规范不变，宿主自动识别）
    private func findDylib(moduleDir: URL) -> URL? {
        let binDir = moduleDir.appendingPathComponent("bin", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: binDir, includingPropertiesForKeys: nil) else { return nil }
        return items.first { $0.pathExtension.lowercased() == "dylib" }
    }

    /// 进程内加载 dylib：dlopen + 调用 OpenListMain 导出（Go c-archive 产物）。
    /// 机制等同 LC 注入 tweak——dlopen ldid 伪签名 dylib 不受 AMFI exec 限制。
    private func startInProcess(module: EscapeModule, dylibURL: URL, logFile: URL) throws {
        let handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_GLOBAL)
        guard let handle else {
            let err = dlerror().map { String(cString: $0) } ?? "未知错误"
            throw BinaryModuleError.spawnFailed("dlopen 失败: \(err)")
        }
        guard let sym = dlsym(handle, "OpenListMain") else {
            throw BinaryModuleError.spawnFailed("dylib 缺少 OpenListMain 导出")
        }
        typealias OpenListMainFn = @convention(c) () -> Int32
        let fn = unsafeBitCast(sym, to: OpenListMainFn.self)
        // 数据目录约定：环境变量 OPENLIST_DATA（dylib 内 os.Getenv 读取）
        setenv("OPENLIST_DATA", module.installURL.path, 1)
        appendLog(logFile, "[host] dlopen 成功，调用 OpenListMain（进程内，随宿主退出）")
        Thread.detachNewThread {
            _ = fn()   // Go runtime 在此线程初始化并阻塞服务
        }
    }

    /// 追加宿主侧日志到模块 run.log（与子进程 stdout/stderr 同文件）
    private func appendLog(_ logFile: URL, _ line: String) {
        let text = "[\(DateFormatter.logStamp)] \(line)\n"
        if let fh = FileHandle(forWritingAtPath: logFile.path) {
            fh.seekToEndOfFile()
            fh.write(text.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? text.data(using: .utf8)!.write(to: logFile)
        }
    }
}

private extension DateFormatter {
    static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

enum BinaryModuleError: LocalizedError {
    case binaryMissing(String)
    case spawnFailed(String)
    case spawnEPERM(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let p): return "二进制文件缺失: \(p)"
        case .spawnFailed(let m): return "启动失败: \(m)"
        case .spawnEPERM(let m): return "启动失败: \(m)"
        }
    }
}
