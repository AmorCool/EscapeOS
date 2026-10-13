import SwiftUI

/// 「禁用通话录音」控制台 —— 「更多 → 禁用通话录音」的二级页。
///
/// 参考项目 AirBeep（原名 Placard，仓库 `LinkPass888/AirBeep`）：把通话录音的开始 /
/// 结束**披露提示音**替换成等长静音，录音本身不受影响。替换写入经 `SandboxFileAccess`
/// （设备侧任意路径文件访问原语），走**设备上真正可用的漏洞利用**（默认 `bad_query`），
/// **不依赖 AirLift**（airlift 是配对 Mac 侧的 PoC，iOS 侧无法独立工作）。
///
/// 界面只保留必要信息：原理说明卡片 + 当前状态 + 两个动作（禁用 / 恢复）。
struct CallRecordingToneView: View {
    @State private var state: CallRecordingToneService.ToneState = .original
    @State private var busy = false
    @State private var alert: ToneAlert?

    var body: some View {
        List {
            Section {
                InfoActionCard(
                    icon: "speaker.slash.fill",
                    title: "禁用通话录音",
                    message: "把通话录音的起止提示音替换为等长静音，录音本身仍正常进行.原始提示音会备份到本机，可随时恢复."
                )
            }

            Section {
                HStack {
                    Text("当前状态")
                    Spacer()
                    Text(statusText)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("状态", systemImage: "waveform")
            } footer: {
                Text("需先在「更多 → 漏洞利用」启用可用的漏洞利用，才能写入系统提示音文件.")
            }

            Section {
                Button {
                    run(.disable)
                } label: {
                    Label("禁用提示音", systemImage: "speaker.slash.fill")
                }
                .disabled(busy || state == .silenced)

                Button {
                    run(.restore)
                } label: {
                    Label("恢复原始提示音", systemImage: "arrow.uturn.backward")
                }
                .disabled(busy || state != .silenced)
            } header: {
                Label("操作", systemImage: "slider.horizontal.3")
            } footer: {
                Text("禁用后建议拨打一次录音验证效果.恢复会从本机备份写回原始提示音.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("禁用通话录音")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            state = await loadState()
        }
        .alert(item: $alert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: - 展示

    private var statusText: String {
        switch state {
        case .original: return "原始提示音"
        case .silenced: return "已禁用（静音）"
        case .unreachable: return "不可达"
        }
    }

    // MARK: - 动作

    /// 一个可发送到后台执行的动作（枚举而非闭包：天然 `Sendable`，跨并发边界无需额外标注）.
    private enum ToneAction: Sendable {
        case disable
        case restore

        func perform() throws {
            switch self {
            case .disable: try CallRecordingToneService.disable()
            case .restore: try CallRecordingToneService.restore()
            }
        }

        var doneMessage: String {
            switch self {
            case .disable: return "已把通话录音提示音替换为静音."
            case .restore: return "已从备份恢复原始提示音."
            }
        }
    }

    /// 在后台线程执行文件 IO + 音频生成（含 `SandboxEscape.consume`，会阻塞），
    /// 完成后回主线程刷新状态。
    private func run(_ action: ToneAction) {
        guard !busy else { return }
        busy = true
        AppHaptics.tap()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try action.perform()
                }.value
                state = await loadState()
                busy = false
                AppHaptics.success()
                alert = ToneAlert(title: "完成", message: action.doneMessage)
            } catch {
                busy = false
                alert = ToneAlert(title: "失败", message: error.localizedDescription)
            }
        }
    }

    /// 状态查询含一次文件读取（阻塞），放到后台执行.
    private func loadState() async -> CallRecordingToneService.ToneState {
        await Task.detached(priority: .utility) {
            CallRecordingToneService.currentState()
        }.value
    }
}

/// 结果 / 错误弹窗内容.
private struct ToneAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
