//
//  ProcessManagerView.swift
//  EscapeOS
//
//  进程管理（汉化移植自 StikDebug 的 Process Inspector）。
//
//  原理：经 LocalDevVPN 隧道（RPPairing 配对文件）连接设备的 app_service，
//  调用 `app_service_list_processes` 枚举全设备进程、`app_service_send_signal`
//  向指定 PID 发送信号（恢复 SIGCONT / 挂起 SIGSTOP / 结束 SIGKILL）。
//  与「启用 JIT / 拉起应用 / 卸载」走的是同一个 RSD 隧道通道，因此在
//  LiveContainer 访客沙盒内同样可用；前提是：配对文件 + LocalDevVPN + 开发者模式。
//
//  设备端 app_service 只回传 pid + 可执行路径，没有 Bundle ID / 友好名，
//  故列表显示名取路径末段（与 StikDebug 原版一致）。
//

import SwiftUI
import Foundation
import Darwin

// MARK: - 进程模型

/// 统一的提示弹窗数据（v0.2.106：替代原先双 alert 通道）。
struct ProcessAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ProcessEntry: Identifiable {
    let pid: Int
    let executablePath: String
    /// 物理内存占用（bytes）。nil = FFI 尚未返回此字段（需 idevice crate 升级）。
    var memoryBytes: Int64? = nil

    var id: Int { pid }

    /// 格式化内存显示（MB/KB）。
    var memoryDisplay: String? {
        guard let bytes = memoryBytes, bytes > 0 else { return nil }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    /// 显示名取可执行路径末段（设备不回传友好名）。
    var displayName: String {
        let components = executablePath.split(separator: "/")
        if let last = components.last, !last.isEmpty {
            return String(last)
        }
        return "进程 \(pid)"
    }
}

// MARK: - 进程操作类型

enum ProcessControlAction: String {
    case resume
    case pause
    case kill

    /// 对应 Unix 信号。
    var signal: Int32 {
        switch self {
        case .resume: return Int32(SIGCONT)
        case .pause:  return Int32(SIGSTOP)
        case .kill:   return Int32(SIGKILL)
        }
    }

    var buttonLabel: String {
        switch self {
        case .resume: return "恢复"
        case .pause:  return "挂起"
        case .kill:   return "结束"
        }
    }

    var systemImage: String {
        switch self {
        case .resume: return "play.circle"
        case .pause:  return "pause.circle"
        case .kill:   return "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .resume: return .green
        case .pause:  return .orange
        case .kill:   return .red
        }
    }

    var progressTitle: String {
        switch self {
        case .resume: return "正在恢复进程"
        case .pause:  return "正在挂起进程"
        case .kill:   return "正在结束进程"
        }
    }

    var timeoutTitle: String {
        switch self {
        case .resume: return "恢复超时"
        case .pause:  return "挂起超时"
        case .kill:   return "结束超时"
        }
    }

    var failureTitle: String {
        switch self {
        case .resume: return "恢复失败"
        case .pause:  return "挂起失败"
        case .kill:   return "结束失败"
        }
    }

    var successTitle: String {
        switch self {
        case .resume: return "进程已恢复"
        case .pause:  return "进程已挂起"
        case .kill:   return "进程已结束"
        }
    }

    func successMessage(for pid: Int) -> String {
        switch self {
        case .resume: return "已向 PID \(pid) 发送 SIGCONT (19)。"
        case .pause:  return "已向 PID \(pid) 发送 SIGSTOP (17)。"
        case .kill:   return "PID \(pid) 已被终止。"
        }
    }

    func timeoutMessage(for pid: Int) -> String {
        switch self {
        case .resume: return "无法确认 PID \(pid) 已恢复，请重试。"
        case .pause:  return "无法确认 PID \(pid) 已挂起，请重试。"
        case .kill:   return "无法确认 PID \(pid) 已结束，请重试。"
        }
    }
}

// MARK: - 服务层（隧道 + app_service FFI）

/// 进程管理服务：复用 JITEnableService 的隧道写法，直接调用 idevice.h 暴露的
/// `app_service_*` C 函数（经 bridging header 可见）。
///
/// v0.2.108 关键修复：
/// - 所有进程操作（枚举 / 发信号）走**同一条串行队列**，禁止并发的
///   `EscapeSpaceProcess` 隧道互相抢占/覆盖；
/// - `app_service_connect_rsd` 与 `tunnel_create_rppairing` 一样加 3 次退避重试，
///   覆盖 RSD 服务发现的偶发 `ServiceNotFound`；
/// - 发信号使用 `UInt32(SIGKILL)` 直接量，与「设备控制」侧完全一致，避免
///   `Int32 → UInt32` 转换在任何编译/平台组合下出现歧义。
final class ProcessManagerService {

    static let shared = ProcessManagerService()
    private init() {}

    /// 串行队列：保证 listProcesses / sendSignal 不并发建隧道。
    /// 同一 hostname 并发 tunnel_create_rppairing 是进程管理 SIGKILL 偶发/持续
    /// 无效的根因之一（RSD 通道竞争）。
    private let operationQueue = DispatchQueue(label: "com.ipaside.escapeos.processmgr", qos: .userInitiated)

    /// EscapeSpace 的配对文件路径（与「应用」页 / 虚拟定位共用）。
    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "ProcessManager", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
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
        return NSError(domain: "ProcessManager", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    // MARK: 隧道

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    private func createTunnel(hostname: String) throws -> TunnelHandles {
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

        // 隧道建立失败自动重试（最多 3 次、短退避）：对齐 DeviceControlService。
        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = hostname.withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn,
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

    /// 连接 app_service，失败自动重试 3 次（覆盖 ServiceNotFound）。
    private func connectAppService(adapter: OpaquePointer, handshake: OpaquePointer) throws -> OpaquePointer {
        var lastError: NSError?
        for attempt in 0..<3 {
            var appService: OpaquePointer?
            if let ffiError = app_service_connect_rsd(adapter, handshake, &appService) {
                lastError = error(from: ffiError, fallback: "连接应用服务失败")
            } else if let appService {
                return appService
            } else {
                lastError = makeError("连接应用服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接应用服务失败")
    }

    // MARK: 枚举进程

    func listProcesses() throws -> [ProcessEntry] {
        try operationQueue.sync {
            var tunnel = try createTunnel(hostname: "EscapeSpaceProcess")
            defer { tunnel.free() }
            guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                throw makeError("隧道未建立")
            }

            let appService = try connectAppService(adapter: adapter, handshake: handshake)
            defer { app_service_free(appService) }

            var processes: UnsafeMutablePointer<ProcessTokenC>?
            var count = UInt(0)
            if let ffiError = app_service_list_processes(appService, &processes, &count) {
                throw error(from: ffiError, fallback: "枚举进程失败")
            }
            defer {
                if let processes { app_service_free_process_list(processes, count) }
            }
            guard let processes else { return [] }

            var result: [ProcessEntry] = []
            result.reserveCapacity(Int(count))
            for index in 0..<Int(count) {
                let p = processes[index]
                let path = p.executable_url.flatMap { String(cString: $0) } ?? "未知"
                result.append(ProcessEntry(pid: Int(p.pid), executablePath: path))
            }
            return result
        }
    }

    // MARK: 发送信号

    // MARK: - 内存查询（v0.3.33：DVT sysmontap physFootprint）

    /// 通过 DVT sysmontap 获取每个进程的 physFootprint（物理内存占用）。
    /// 返回 [pid: bytes]，进程已退出时不出现在字典中。
    func fetchMemoryUsage() throws -> [Int32: UInt64] {
        try operationQueue.sync {
            var tunnel = try createTunnel(hostname: "EscapeSpaceSysmon")
            defer { tunnel.free() }
            guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                throw makeError("隧道未建立")
            }

            // 1. RemoteServer
            var server: OpaquePointer?
            if let err = remote_server_connect_rsd(adapter, handshake, &server) {
                throw error(from: err, fallback: "创建 RemoteServer 失败")
            }
            guard let server else { throw makeError("RemoteServer 为空") }
            defer { remote_server_free(server) }

            // 2. SysmontapClient
            var sysmon: OpaquePointer?
            if let err = sysmontap_new(server, &sysmon) {
                throw error(from: err, fallback: "创建 Sysmontap 失败")
            }
            guard let sysmon else { throw makeError("Sysmontap 为空") }
            defer { sysmontap_free(sysmon) }

            // 3. 配置：process_attributes = ["physFootprint"]
            guard let attrBuf = strdup("physFootprint") else {
                throw makeError("strdup 失败")
            }
            defer { free(UnsafeMutableRawPointer(attrBuf)) }
            var attrPtrs: [UnsafePointer<CChar>?] = [UnsafePointer(attrBuf), nil]

            var config = IdeviceSysmontapConfig(
                interval_ms: 500,
                process_attributes: attrPtrs,
                process_attributes_count: 1,
                system_attributes: nil,
                system_attributes_count: 0
            )
            if let err = sysmontap_set_config(sysmon, &config) {
                throw error(from: err, fallback: "配置 Sysmontap 失败")
            }

            // 4. 启动
            if let err = sysmontap_start(sysmon) {
                throw error(from: err, fallback: "启动 Sysmontap 失败")
            }

            // 5. 获取一次样本
            var processes: plist_t? = nil
            var system: plist_t? = nil
            var cpu: plist_t? = nil
            if let err = sysmontap_next_sample(sysmon, &processes, &system, &cpu) {
                throw error(from: err, fallback: "获取内存样本失败")
            }

            defer {
                if let p = processes { plist_free(p) }
                if let s = system { plist_free(s) }
                if let c = cpu { plist_free(c) }
            }

            // 6. 停止
            sysmontap_stop(sysmon)

            // 7. 解析 processes dict → { "pid": [physFootprint_value] }
            var result: [Int32: UInt64] = [:]
            guard let procs = processes else { return result }

            var iter: plist_dict_iter? = nil
            plist_dict_new_iter(procs, &iter)
            defer { if let it = iter { free(it) } }

            while true {
                var key: UnsafeMutablePointer<CChar>? = nil
                var val: plist_t? = nil
                plist_dict_next_item(procs, iter, &key, &val)
                guard let k = key else { break }
                let pidStr = String(cString: k)
                free(k)
                guard let pid = Int32(pidStr) else { continue }

                // val 是数组，第一个元素 = physFootprint
                guard let v = val else { continue }
                let item = plist_array_get_item(v, 0)
                guard let footprint = item, footprint != nil else { continue }
                var mem: UInt64 = 0
                plist_get_uint_val(footprint, &mem)
                if mem > 0 { result[pid] = mem }
            }

            return result
        }
    }

    func sendSignal(_ action: ProcessControlAction, toPID pid: Int) throws {
        try operationQueue.sync {
            var tunnel = try createTunnel(hostname: "EscapeSpaceProcess")
            defer { tunnel.free() }
            guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                throw makeError("隧道未建立")
            }

            let appService = try connectAppService(adapter: adapter, handshake: handshake)
            defer { app_service_free(appService) }

            var response: UnsafeMutablePointer<SignalResponseC>?
            let signalValue: UInt32 = {
                switch action {
                case .resume: return UInt32(SIGCONT)
                case .pause:  return UInt32(SIGSTOP)
                case .kill:   return UInt32(SIGKILL)
                }
            }()
            let ffiError = app_service_send_signal(appService, UInt32(pid), signalValue, &response)
            if let ffiError {
                throw error(from: ffiError, fallback: "发送信号失败")
            }
            defer { if let response { app_service_free_signal_response(response) } }
        }
    }
}

// MARK: - 视图模型

@MainActor
final class ProcessManagerViewModel: ObservableObject {
    @Published private(set) var processes: [ProcessEntry] = []
    @Published var searchText: String = ""
    @Published var isRefreshing = false
    @Published private(set) var activeControlState: (pid: Int, action: ProcessControlAction)?
    /// 统一的提示弹窗通道（操作结果 / 错误）。v0.2.106：此前双 .alert 并存，
    /// 后注册覆盖先注册导致「进程已结束」等操作弹窗从不弹出。
    @Published var alertItem: ProcessAlert?

    private var refreshTask: Task<Void, Never>?
    private var controlTimeoutTask: Task<Void, Never>?
    /// SIGKILL 后的二次验证任务（检查目标 PID 是否真的消失）。
    private var killVerifyTask: Task<Void, Never>?

    var filteredProcesses: [ProcessEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return processes }
        return processes.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.executablePath.localizedCaseInsensitiveContains(query) ||
            "\($0.pid)".contains(query)
        }
    }

    var isRunningControlAction: Bool { activeControlState != nil }

    func activeControl(for process: ProcessEntry) -> ProcessControlAction? {
        guard activeControlState?.pid == process.pid else { return nil }
        return activeControlState?.action
    }

    func startAutoRefresh() {
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { break }
                await MainActor.run { self.refresh() }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        controlTimeoutTask?.cancel()
        controlTimeoutTask = nil
        killVerifyTask?.cancel()
        killVerifyTask = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            do {
                let entries = try ProcessManagerService.shared.listProcesses()

                // v0.3.37：带 5 秒超时的内存查询（sysmontap next_sample 是阻塞式的，
                // 用 semaphore + background queue 防止挂死刷新流程）
                var memMap: [Int32: UInt64] = [:]
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    do {
                        memMap = try ProcessManagerService.shared.fetchMemoryUsage()
                    } catch {
                        print("[ProcessManager] 内存查询失败: \(error.localizedDescription)")
                    }
                    semaphore.signal()
                }
                let timeoutResult = semaphore.wait(timeout: .now() + 5)
                if timeoutResult == .timedOut {
                    print("[ProcessManager] 内存查询超时（5s），跳过")
                }

                // 合并内存数据到 entries
                var enriched = entries
                for i in enriched.indices {
                    if let mem = memMap[Int32(enriched[i].pid)] {
                        enriched[i].memoryBytes = Int64(mem)
                    }
                }

                await MainActor.run {
                    guard let self else { return }
                    self.processes = enriched
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.alertItem = ProcessAlert(title: "加载进程失败", message: error.localizedDescription)
                    self.isRefreshing = false
                }
            }
        }
    }

    /// SIGKILL 最终复核（v0.2.107）：1.5 秒后重新枚举进程，**无论结果如何都弹
    /// 一个结论**——目标 PID 消失 → 「进程已结束」；仍在 → 「进程可能仍在运行」
    /// （受保护 / 前台 App 被 SpringBoard 拉起 / 权限不足）。
    /// 注意：@MainActor 类内 `Task { }` 继承主线程隔离，self 非 Optional，
    /// 用 `[self]` 强捕获。
    private func verifyKill(_ targetPID: Int) {
        killVerifyTask?.cancel()
        killVerifyTask = Task { [self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let stillAlive = await Task.detached(priority: .utility) {
                (try? ProcessManagerService.shared.listProcesses())?
                    .contains { $0.pid == targetPID } ?? false
            }.value
            guard !Task.isCancelled else { return }
            self.killVerifyTask = nil
            self.refresh()
            if stillAlive {
                self.alertItem = ProcessAlert(title: "进程可能仍在运行", message: "PID \(targetPID) 已发送 SIGKILL，但刷新后仍出现在进程列表中。常见原因：系统关键进程受保护、前台 App 被 SpringBoard 自动拉起、或设备 app_service 权限不足。")
            } else {
                self.alertItem = ProcessAlert(title: "进程已结束", message: "PID \(targetPID) 已确认从进程列表中消失。")
            }
        }
    }

    func control(_ action: ProcessControlAction, process: ProcessEntry) {
        guard activeControlState == nil else {
            alertItem = ProcessAlert(title: "操作进行中", message: "上一项进程操作尚未完成，请稍候。")
            return
        }

        let targetPID = process.pid
        activeControlState = (targetPID, action)
        controlTimeoutTask?.cancel()
        controlTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            if self.activeControlState?.pid == targetPID && self.activeControlState?.action == action {
                await MainActor.run {
                    self.activeControlState = nil
                    self.alertItem = ProcessAlert(title: action.timeoutTitle, message: action.timeoutMessage(for: targetPID))
                }
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try ProcessManagerService.shared.sendSignal(action, toPID: targetPID)
                await MainActor.run {
                    guard let self else { return }
                    self.controlTimeoutTask?.cancel()
                    self.controlTimeoutTask = nil
                    guard self.activeControlState?.pid == targetPID && self.activeControlState?.action == action else { return }
                    self.activeControlState = nil
                    self.refresh()
                    if action == .kill {
                        // SIGKILL：不立即弹成功，等 1.5 秒复核结果后给**一个**最终
                        // 结论弹窗（已结束 / 可能仍在运行），保证一定有反馈
                        // （v0.2.107：避免成功弹窗被复核弹窗覆盖导致用户看不到）。
                        self.verifyKill(targetPID)
                    } else {
                        self.alertItem = ProcessAlert(title: action.successTitle, message: action.successMessage(for: targetPID))
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.controlTimeoutTask?.cancel()
                    self.controlTimeoutTask = nil
                    guard self.activeControlState?.pid == targetPID && self.activeControlState?.action == action else { return }
                    self.activeControlState = nil
                    self.alertItem = ProcessAlert(title: action.failureTitle, message: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - 视图

struct ProcessManagerView: View {
    @StateObject private var viewModel = ProcessManagerViewModel()
    @State private var killCandidate: ProcessEntry?
    @State private var killConfirmTask: Task<Void, Never>?

    private var hasPairing: Bool { TunnelContext.shared.hasPairingFile }

    var body: some View {
        // 注意：不嵌套 NavigationStack！本页由 MoreView 的 NavigationView push 进入，
        // 嵌套导航栈会导致导航栏高度异常、标题/按钮错位（"tab 栏往下"的真凶）。
        // 与「描述文件管理」（AppExpiryView）同构：直接 List + navigationTitle。
        content
            .navigationTitle("进程管理")
            .navigationBarTitleDisplayMode(.inline)
            // 系统搜索栏（v0.2.90 样式）。
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索进程"
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { viewModel.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing)
                }
            }
            // 导航栏不设置 toolbarBackground，保持系统默认半透明毛玻璃效果，
            // 与「描述文件管理」（AppExpiryView）一致，可透视下方滚动内容。
            .task { viewModel.startAutoRefresh() }
            .onDisappear { viewModel.stopAutoRefresh() }
            .alert(item: $viewModel.alertItem) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("好"), action: {
                        if item.title == "加载进程失败" { viewModel.refresh() }
                    })
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if viewModel.processes.isEmpty && !viewModel.isRefreshing {
                Section {
                    if !hasPairing {
                        Label("未检测到配对文件", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("进程管理需要：① 配对文件（在「应用」页导入）；② LocalDevVPN 已连接；③ 开发者模式已开启。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未找到运行中的进程。")
                            .foregroundStyle(.secondary)
                        Text("设备可能处于空闲状态，或隧道尚未就绪；点击右上角刷新重试。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    if viewModel.filteredProcesses.isEmpty {
                        Text("没有匹配的进程。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.filteredProcesses) { process in
                            ProcessRow(
                                process: process,
                                activeControl: viewModel.activeControl(for: process),
                                isBusy: viewModel.isRunningControlAction,
                                isConfirming: killCandidate?.pid == process.pid,
                                onResumeTap: { viewModel.control(.resume, process: $0) },
                                onPauseTap: { viewModel.control(.pause, process: $0) },
                                onKillTap: { handleKillTap(for: $0) }
                            )
                        }
                    }
                } header: {
                    Text("运行中的进程（\(viewModel.processes.count)）")
                } footer: {
                    Text("恢复（SIGCONT）/ 挂起（SIGSTOP）/ 结束（SIGKILL）经由设备隧道下发，仅对当前设备生效。对系统关键进程发送结束信号可能因权限不足而失败。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0)
        .refreshable { viewModel.refresh() }
    }

    private func handleKillTap(for process: ProcessEntry) {
        if killCandidate?.pid == process.pid {
            killConfirmTask?.cancel()
            killConfirmTask = nil
            killCandidate = nil
            viewModel.control(.kill, process: process)
        } else {
            killCandidate = process
            killConfirmTask?.cancel()
            killConfirmTask = Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    if killCandidate?.pid == process.pid {
                        killCandidate = nil
                    }
                }
            }
        }
    }
}

// MARK: - 进程行

private struct ProcessRow: View {
    let process: ProcessEntry
    let activeControl: ProcessControlAction?
    let isBusy: Bool
    let isConfirming: Bool
    let onResumeTap: (ProcessEntry) -> Void
    let onPauseTap: (ProcessEntry) -> Void
    let onKillTap: (ProcessEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(process.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(process.memoryDisplay ?? "—")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(process.memoryDisplay != nil ? .white : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(process.memoryDisplay != nil ? Color.blue : Color.secondary.opacity(0.15)))
                Text("PID \(process.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(process.executablePath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Spacer()
                if activeControl != nil {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.accentColor)
                } else {
                    HStack(spacing: 8) {
                        Button {
                            onResumeTap(process)
                        } label: {
                            Image(systemName: ProcessControlAction.resume.systemImage)
                                .font(.title3)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(ProcessControlAction.resume.tint)
                        .labelStyle(.iconOnly)
                        .disabled(isBusy)

                        Button {
                            onPauseTap(process)
                        } label: {
                            Image(systemName: ProcessControlAction.pause.systemImage)
                                .font(.title3)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(ProcessControlAction.pause.tint)
                        .labelStyle(.iconOnly)
                        .disabled(isBusy)

                        Button {
                            onKillTap(process)
                        } label: {
                            if isConfirming {
                                Label("确认结束", systemImage: "checkmark.circle.fill")
                                    .font(.caption2.weight(.semibold))
                            } else {
                                Image(systemName: ProcessControlAction.kill.systemImage)
                                    .font(.title3)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(isConfirming ? .green : ProcessControlAction.kill.tint)
                        // 固定 .titleOnly：确认态 label 是 Label（只出文字「确认结束」），
                        // 非确认态 label 是 Image（labelStyle 对 Image 无效，照常显图标）。
                        // 不能写三元 `isConfirming ? .titleOnly : .iconOnly`——两种
                        // LabelStyle 类型不同，编译器无法统一（v0.2.108 run 33253523553 报错）。
                        .labelStyle(.titleOnly)
                        .disabled(isBusy)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
