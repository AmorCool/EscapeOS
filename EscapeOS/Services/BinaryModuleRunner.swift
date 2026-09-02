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
    /// automatic=true 为自启动（受崩溃循环守卫保护）；false 为用户手动点启动（总是重试）
    func start(module: EscapeModule, automatic: Bool = true) {
        guard let bin = module.binary else { return }
        guard runningProcesses[module.id] == nil else { return }

        // 崩溃循环守卫：若上一次启动后宿主没活到清除标记（8s），判定崩溃 → 跳过自启动，
        // 保证用户还能进 App 看日志/关模块（否则每次进入 2s 后必崩，永远改不回来）
        let flag = Self.inFlightKey(module.id)
        if automatic && UserDefaults.standard.bool(forKey: flag) {
            let msg = "上次启动疑似导致崩溃，已跳过自动启动（查看日志后可手动启动）"
            appendLog(
                ModuleService.shared.installURL(for: module.id).appendingPathComponent("run.log"),
                "[host] \(msg)")
            setError(module.id, msg)
            return
        }
        UserDefaults.standard.set(true, forKey: flag)

        let dataDir = ModuleService.shared.dataURL(for: module.id)
        let logFile = ModuleService.shared.installURL(for: module.id).appendingPathComponent("run.log")

        // 撑过 8s 视为启动成功，清除崩溃标记
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            UserDefaults.standard.set(false, forKey: flag)
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            self.runBinaryModule(module, bin: bin, dataDir: dataDir, logFile: logFile)
        }
    }

    private static func inFlightKey(_ id: String) -> String { "Binary.startInFlight.\(id)" }

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
        // 数据目录可写性门禁（v0.3.74 闪退根修）：
        // OpenList bootstrap 在目录不可写时走 log.Fatalf → os.Exit → 连宿主一起杀。
        // 这里先建目录 + 写探针，失败就放弃启动并把原因报给 UI（宿主永不死）。
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let probe = dataDir.appendingPathComponent(".write-probe")
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            let msg = "数据目录不可写：\(error.localizedDescription)（LiveContainer 24h 磁盘写入配额可能已满——等待重置或重启设备）"
            appendLog(logFile, "[host] \(msg)；放弃启动以避免 os.Exit 杀宿主")
            setError(module.id, msg)
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

/// OpenList 进程入口（C 函数指针，供 pthread_create 使用）
/// 数据目录作为 **参数** 传入给 Go（Go 的 env 在 runtime 初始化时已快照，
/// setenv 事后设置对 os.Getenv 不可见——v0.3.78 闪退根因）
private let openlistDataDirBox = DataDirBox()

final class DataDirBox {
    private let lock = NSLock()
    private var _path: String = ""
    var path: String { lock.lock(); defer { lock.unlock() }; return _path }
    func set(_ p: String) { lock.lock(); _path = p; lock.unlock() }
}

private let openlistEntry: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { _ in
    _ = OpenListMain(openlistDataDirBox.path)   // Go runtime 首次调用时初始化；阻塞服务，永不返回
    return nil
}

    /// 调用静态链接进宿主的 OpenListMain（sap.h 经桥接头暴露给 Swift，与 Sap*
    /// 同一 Go runtime）。数据目录来自 OPENLIST_DATA；Go stderr/log 落盘 data/stderr.log；
    /// bridge 绝不 os.Exit。
    /// 跑在 8MB 大栈 pthread 上（NSThread 默认 512KB，Go runtime + 数百个包 init 链可能爆栈）。
    nonisolated private func startInProcess(dataDir: URL, logFile: URL) throws {
        setenv("OPENLIST_DATA", dataDir.path, 1)   // 兜底（Go 可能读不到 env 快照后的值）
        openlistDataDirBox.set(dataDir.path)        // 真正生效：作为参数传给 Go
        // 关键诊断：把宿主 fd 2 重定向到文件——Go runtime 在初始化阶段的
        // throw/fatal（发生在我们任何 Go 代码之前）原本只写进程 stderr，在 LC 里
        // 直接丢失。抓下来后 SSH: cat Modules/<id>/data/go_stderr.log 即可看到真因。
        let goErr = dataDir.appendingPathComponent("go_stderr.log")
        let fd = open(goErr.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            dup2(fd, STDERR_FILENO)
            close(fd)
        }
        appendLog(logFile, "[host] 调用内置 OpenListMain（进程内，随宿主退出）")
        var attr = pthread_attr_t()
        guard pthread_attr_init(&attr) == 0 else {
            throw BinaryModuleError.spawnFailed("pthread_attr_init 失败")
        }
        pthread_attr_setstacksize(&attr, 8 * 1024 * 1024)
        var tid: pthread_t?
        let rc = pthread_create(&tid, &attr, openlistEntry, nil)
        pthread_attr_destroy(&attr)
        guard rc == 0 else {
            throw BinaryModuleError.spawnFailed("pthread_create 失败：\(rc)")
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
