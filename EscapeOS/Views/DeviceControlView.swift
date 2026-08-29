import SwiftUI

/// 「更多」左上角入口：设备控制（重启 SpringBoard / 网页崩溃 / 重启设备 / 关机 / 恢复模式）。
///
/// - 重启 SpringBoard（SIGKILL）与网页崩溃（RespringView 内存压力）：桌面立即重启。
/// - 重启设备 / 关机 / 进入恢复模式：经配对文件 + LocalDevVPN 隧道的 RSD 通道
///   （diagnostics relay / lockdownd），需要已连接隧道。
/// - 所有危险操作均弹确认框；恢复模式额外强调风险。
///
/// ⚠️ 已知坑（v0.2.104 修复）：同一视图链上不要挂两个 `.alert(item:)`——
/// 后注册的会覆盖先注册的，导致确认弹窗不弹、点击无反应。这里统一走
/// 单个 `alertItem` 通道（确认 / 结果两种形态）。
struct DeviceControlView: View {
    @Environment(\.dismiss) private var dismiss

    enum DeviceAction: String, Identifiable {
        case respringKill = "进程终止（SIGKILL）"
        case webCrash = "网页崩溃"
        case restart = "重启设备"
        case shutdown = "关机"
        case recovery = "进入恢复模式"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .respringKill: return "arrow.counterclockwise.circle.fill"
            case .webCrash: return "safari.fill"
            case .restart: return "power.circle.fill"
            case .shutdown: return "power"
            case .recovery: return "wrench.and.screwdriver.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .respringKill: return "向 SpringBoard 发送 SIGKILL，桌面立即重启（App 进程保留）"
            case .webCrash: return "本机内存压力挤崩 SpringBoard，模拟真实崩溃（无需隧道）"
            case .restart: return "发送重启指令，设备重启后需解锁（需 LocalDevVPN + 配对）"
            case .shutdown: return "发送关机指令，需长按电源键开机（需 LocalDevVPN + 配对）"
            case .recovery: return "设备进入恢复模式，退出需连接电脑（需 LocalDevVPN + 配对）"
            }
        }

        var confirmTitle: String {
            switch self {
            case .respringKill: return "重启 SpringBoard？"
            case .webCrash: return "网页崩溃 SpringBoard？"
            case .restart: return "重启设备？"
            case .shutdown: return "关机？"
            case .recovery: return "进入恢复模式？"
            }
        }

        var confirmMessage: String {
            switch self {
            case .respringKill:
                return "将向 SpringBoard 发送 SIGKILL，桌面会立即重启（黑屏数秒），已打开的 App 进程保留。"
            case .webCrash:
                return "将在本机加载高压力网页把 SpringBoard 挤到内存不足自动重启，模拟真实崩溃。"
            case .restart:
                return "设备将重新启动，重启后需要解锁。请先关闭正在进行的传输与任务。"
            case .shutdown:
                return "设备将关机，需要长按电源键开机。请先确认重要数据已保存。"
            case .recovery:
                return "设备将进入恢复模式（屏幕显示连接电脑图标）。退出恢复模式需要数据线连接电脑或按键组合，操作前请确认数据已备份。"
            }
        }
    }

    /// 统一的 alert 通道：确认弹窗（dangerous action）或结果/错误提示。
    private enum AlertItem: Identifiable {
        case confirm(DeviceAction)
        case notice(title: String, message: String)

        var id: String {
            switch self {
            case .confirm(let action): return "confirm-\(action.id)"
            case .notice(let title, _): return "notice-\(title)"
            }
        }
    }

    @State private var alertItem: AlertItem?
    @State private var isRunning = false
    @State private var runningTitle = "处理中…"
    @State private var showWebCrash = false

    private let service = DeviceControlService.shared

    var body: some View {
        List {
            Section {
                actionRow(.respringKill)
                actionRow(.webCrash)
            } header: {
                Text("重启 SpringBoard")
            } footer: {
                Text("两种方式都会让桌面（主屏）重启；已打开的 App 进程不受影响。")
            }

            Section {
                actionRow(.restart)
                actionRow(.shutdown)
            } header: {
                Text("电源管理")
            } footer: {
                Text("需要配对文件 + LocalDevVPN 隧道；与「进程管理 / 虚拟定位」同一套通道。")
            }

            Section {
                actionRow(.recovery)
            } header: {
                Text("恢复模式")
            } footer: {
                Text("进入恢复模式后设备无法正常使用，退出需连接电脑。请谨慎操作。")
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 0)
        .navigationTitle("设备控制")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
                    .disabled(isRunning)
            }
        }
        .alert(item: $alertItem) { item in
            alertView(for: item)
        }
        .fullScreenCover(isPresented: $showWebCrash) {
            // 黑屏 + 压力网页：SpringBoard 被挤崩后桌面自动重启。
            // 容器整体纯黑，不显示任何提示条（视觉干净，v0.2.105）。
            ZStack {
                Color.black.ignoresSafeArea()
                RespringView()
                    .ignoresSafeArea()
            }
        }
        .overlay {
            if isRunning {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.15)
                        Text(runningTitle)
                            .font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private func alertView(for item: AlertItem) -> Alert {
        switch item {
        case .confirm(let action):
            return Alert(
                title: Text(action.confirmTitle),
                message: Text(action.confirmMessage),
                primaryButton: .destructive(Text("确定")) {
                    execute(action)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        case .notice(let title, let message):
            return Alert(title: Text(title), message: Text(message), dismissButton: .default(Text("好")))
        }
    }

    private func actionRow(_ action: DeviceAction) -> some View {
        Button {
            alertItem = .confirm(action)
        } label: {
            actionRowLabel(action)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(isRunning)
    }

    private func actionRowLabel(_ action: DeviceAction) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: action.icon, tint: actionTint(action), symbolSize: 20, frameSize: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(action.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(action.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func actionTint(_ action: DeviceAction) -> Color {
        switch action {
        case .respringKill, .webCrash: return .blue
        case .restart: return .orange
        case .shutdown: return .red
        case .recovery: return .purple
        }
    }

    private func execute(_ action: DeviceAction) {
        switch action {
        case .webCrash:
            showWebCrash = true
        case .respringKill, .restart, .shutdown, .recovery:
            runViaTunnel(action)
        }
    }

    private func runViaTunnel(_ action: DeviceAction) {
        isRunning = true
        runningTitle = "正在执行「\(action.rawValue)」…"
        Task.detached(priority: .userInitiated) { [service] in
            do {
                switch action {
                case .respringKill:
                    try service.respringSpringBoard()
                case .restart:
                    try service.restartDevice()
                case .shutdown:
                    try service.shutdownDevice()
                case .recovery:
                    try service.enterRecovery()
                case .webCrash:
                    break
                }
                await MainActor.run {
                    self.isRunning = false
                    // 指令已送达：重启/关机/恢复模式会打断连接，无需等待回执。
                    self.alertItem = .notice(
                        title: "指令已发送",
                        message: "「\(action.rawValue)」指令已送达设备，请稍候。"
                    )
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.alertItem = .notice(title: "操作失败", message: error.localizedDescription)
                }
            }
        }
    }
}
