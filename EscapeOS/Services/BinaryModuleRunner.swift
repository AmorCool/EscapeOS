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

    /// 启动模块二进制（全程后台：Go runtime 初始化 + 服务启动可能数秒，绝不占主线程）
    /// 方案 A（v0.3.73）：OpenListMain 已静态链接进宿主 app（与 Sap* 共用单一 Go
    /// runtime，sap.h 直接暴露给 Swift）。进程内直接调用——无 dylib、无第二 runtime、
    /// 无 AMFI exec 限制。此前 dlopen 第二 Go runtime 的方案在初始化即崩（run.log 实锤）。
    func start(module: EscapeModule) {
        guard let bin = module.binary else { return }
        guard runningProcesses[module.id] == nil else { return }

        let dataDir = ModuleService.shared.dataURL(for: module.id)
        let logFile = ModuleService.shared.installURL(for: module.id).appendingPathComponent("run.log")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            self.runBinaryModule(module, bin: bin, dataDir: dataDir, logFile: logFile)
        }
    }

    /// 后台执行体（非隔离：Go 启动全在这里，状态写回走主线程）
    nonisolated private func runBinaryModule(
        _ module: EscapeModule, bin: BinaryConfig,
        dataDir: URL, logFile: URL
    ) {
        // 端口预检：端口被占时绝不调 Go——进程内任何 os.Exit 都会连宿主一起杀
        if let port = bin.port, isPortInUse(UInt16(port)) {
            appendLog(logFile, "[host] 端口 \(port) 已被占用，放弃启动（服务可能已在运行）")
            setError(module.id, "端口 \(port) 已被占用——服务可能已在运行")
            return
        }
        do {
            try startInProcess(dataDir: dataDir, logFile: logFile)
            appendLog(logFile, "[host] 进程内启动成功（随宿主退出）")
            setRunningInProcess(module.id)
        } catch {
            appendLog(logFile, "[host] 进程内启动失败: \(error.localizedDescription)")
            setError(module.id, "启动失败: \(error.localizedDescription)")
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

    // MARK: 进程内启动（方案 A：单一 Go runtime，v0.3.73）

    /// 调用静态链接进宿主的 OpenListMain（sap.h 经桥接头暴露给 Swift，与 Sap*
    /// 同一 Go runtime——此前 dlopen 第二 runtime 在初始化即崩，run.log 实锤）。
    /// 数据目录来自 OPENLIST_DATA；Go stderr/log 落盘 data/stderr.log；
    /// bridge 绝不 os.Exit。调用后该后台线程永久阻塞服务。
    nonisolated private func startInProcess(dataDir: URL, logFile: URL) throws {
        setenv("OPENLIST_DATA", dataDir.path, 1)
        appendLog(logFile, "[host] 调用内置 OpenListMain（进程内，随宿主退出）")
        Thread.detachNewThread {
            _ = OpenListMain()   // Go runtime 首次调用时初始化并阻塞服务
        }
    }

    /// 端口占用检测（本机回环，connect 立即返回）
    nonisolated private func isPortInUse(_ port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    /// 追加宿主侧日志到模块 run.log（与子进程 stdout/stderr 同文件）
    nonisolated private func appendLog(_ logFile: URL, _ line: String) {
        let text = "[\(DateFormatter.logStamp)] \(line)\n"
        if let fh = FileHandle(forWritingAtPath: logFile.path) {
            fh.seekToEndOfFile()
            fh.write(text.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? text.data(using: .utf8)!.write(to: logFile)
        }
    }

    // MARK: 状态写回（主线程队列）
    nonisolated private func setRunningInProcess(_ id: String) {
        DispatchQueue.main.async {
            self.inProcessModules.insert(id)
            self.runningProcesses[id] = -2
            self.startErrors[id] = nil
            print("[Binary][\(id)] 已进程内启动")
        }
    }
    nonisolated private func setRunningProcess(_ id: String, _ pid: pid_t) {
        DispatchQueue.main.async {
            self.runningProcesses[id] = pid
            self.inProcessModules.remove(id)
            self.startErrors[id] = nil
            print("[Binary][\(id)] 已启动 pid=\(pid)")
        }
    }
    nonisolated private func setError(_ id: String, _ msg: String) {
        DispatchQueue.main.async {
            self.startErrors[id] = msg
            print("[Binary][\(id)] \(msg)")
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
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let m): return "启动失败: \(m)"
        }
    }
}
