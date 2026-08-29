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

struct ProcessEntry: Identifiable {
    let pid: Int
    let executablePath: String

    var id: Int { pid }

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
final class ProcessManagerService {

    static let shared = ProcessManagerService()
    private init() {}

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

        // 隧道建立失败自动重试（最多 3 次、短退避）：对齐 JITEnableService。
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

    // MARK: 枚举进程

    func listProcesses() throws -> [ProcessEntry] {
        var tunnel = try createTunnel(hostname: "EscapeSpaceProcess")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        var appService: OpaquePointer?
        if let ffiError = app_service_connect_rsd(adapter, handshake, &appService) {
            throw error(from: ffiError, fallback: "连接应用服务失败")
        }
        guard let appService else { throw makeError("连接应用服务失败") }
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

    // MARK: 发送信号

    func sendSignal(_ action: ProcessControlAction, toPID pid: Int) throws {
        var tunnel = try createTunnel(hostname: "EscapeSpaceProcess")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        var appService: OpaquePointer?
        if let ffiError = app_service_connect_rsd(adapter, handshake, &appService) {
            throw error(from: ffiError, fallback: "连接应用服务失败")
        }
        guard let appService else { throw makeError("连接应用服务失败") }
        defer { app_service_free(appService) }

        var response: UnsafeMutablePointer<SignalResponseC>?
        let ffiError = app_service_send_signal(appService, UInt32(pid), UInt32(action.signal), &response)
        if let ffiError {
            throw error(from: ffiError, fallback: "发送信号失败")
        }
        if let response { app_service_free_signal_response(response) }
    }
}

// MARK: - 视图模型

@MainActor
final class ProcessManagerViewModel: ObservableObject {
    @Published private(set) var processes: [ProcessEntry] = []
    @Published var searchText: String = ""
    @Published var isRefreshing = false
    @Published var showErrorAlert = false
    @Published var errorAlertTitle = ""
    @Published var errorAlertMessage = ""
    @Published private(set) var activeControlState: (pid: Int, action: ProcessControlAction)?
    @Published var showActionAlert = false
    @Published var actionAlertTitle = ""
    @Published var actionAlertMessage = ""

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
                await MainActor.run {
                    guard let self else { return }
                    self.processes = entries
                    self.isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.errorAlertTitle = "加载进程失败"
                    self.errorAlertMessage = error.localizedDescription
                    self.showErrorAlert = true
                    self.isRefreshing = false
                }
            }
        }
    }

    /// SIGKILL 二次验证：1.5 秒后重新枚举进程，若目标 PID 仍在则如实提示
    /// （进程受保护 / 前台 App 被 SpringBoard 自动拉起 / 权限不足）。
    private func verifyKill(_ targetPID: Int) {
        killVerifyTask?.cancel()
        killVerifyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            let stillAlive = await Task.detached(priority: .utility) {
                (try? ProcessManagerService.shared.listProcesses())?
                    .contains { $0.pid == targetPID } ?? false
            }.value
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.killVerifyTask = nil
                self.refresh()
                if stillAlive {
                    self.actionAlertTitle = "进程可能仍在运行"
                    self.actionAlertMessage = "PID \(targetPID) 已发送 SIGKILL，但刷新后仍出现在进程列表中。常见原因：系统关键进程受保护、前台 App 被 SpringBoard 自动拉起、或设备 app_service 权限不足。"
                    self.showActionAlert = true
                }
            }
        }
    }

    func control(_ action: ProcessControlAction, process: ProcessEntry) {
        guard activeControlState == nil else {
            actionAlertTitle = "操作进行中"
            actionAlertMessage = "上一项进程操作尚未完成，请稍候。"
            showActionAlert = true
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
                    self.actionAlertTitle = action.timeoutTitle
                    self.actionAlertMessage = action.timeoutMessage(for: targetPID)
                    self.showActionAlert = true
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
                    self.actionAlertTitle = action.successTitle
                    self.actionAlertMessage = action.successMessage(for: targetPID)
                    self.showActionAlert = true
                    self.refresh()
                    // SIGKILL 二次验证：稍等后刷新列表，确认目标 PID 是否真的消失。
                    // 前台 App 被 kill 后可能被 SpringBoard 立即拉起；系统关键进程
                    // 可能受保护 —— 这些情况如实告知，避免"点了没用"的困惑（v0.2.105）。
                    if action == .kill {
                        self.verifyKill(targetPID)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.controlTimeoutTask?.cancel()
                    self.controlTimeoutTask = nil
                    guard self.activeControlState?.pid == targetPID && self.activeControlState?.action == action else { return }
                    self.activeControlState = nil
                    self.actionAlertTitle = action.failureTitle
                    self.actionAlertMessage = error.localizedDescription
                    self.showActionAlert = true
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
            .alert(viewModel.actionAlertTitle, isPresented: $viewModel.showActionAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.actionAlertMessage)
            }
            .alert(viewModel.errorAlertTitle, isPresented: $viewModel.showErrorAlert) {
                Button("重试") { viewModel.refresh() }
                Button("好", role: .cancel) {}
            } message: {
                Text(viewModel.errorAlertMessage)
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
                                Label("确认", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .font(.title3)
                            } else {
                                Image(systemName: ProcessControlAction.kill.systemImage)
                                    .font(.title3)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(isConfirming ? .green : ProcessControlAction.kill.tint)
                        .labelStyle(.iconOnly)
                        .disabled(isBusy)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
