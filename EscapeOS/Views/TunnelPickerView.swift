import SwiftUI

/// 「更多 → 设置」里的「隧道」三选一（渲染在 `SettingsForm` 的 `Form` 里，本身是一个 `Section`）.
///
/// 三种方式的定位与诚实说明见 `EscapeOS/Engine/TunnelProvider.swift` 的 `TunnelKind`.
/// 本视图只负责呈现与选择：模型 `TunnelKind`、持久化键 `TunnelManager.kindKey`、
/// 权限探测 `VPNPermissionProbe` 全部来自引擎层 —— **本视图不另造同名类型**
/// （原脚手架里的占位 `TunnelKind` / `BuiltInTunnelEntitlement` 已并入抽象层）.
struct TunnelPickerView: View {
    /// 持久化键来自 `TunnelManager`（与引擎读取同键）. 默认 `localDevVPN` ⇒ 既有链路不动.
    @AppStorage(TunnelManager.kindKey) private var kindRaw = TunnelKind.localDevVPN.rawValue

    /// 内置隧道的 VPN 权限探测结果. 默认取同步判定，`.task` 里再用 Network Extension 异步复核.
    @State private var builtInAvailability: TunnelAvailability = BuiltInTunnel().availability

    var body: some View {
        Section {
            row(for: .localDevVPN, subtitle: TunnelKind.localDevVPN.detail)
            row(for: .shadowrocket,
                subtitle: shadowrocketSubtitle,
                enabled: TunnelManager.provider(for: .shadowrocket).availability.isAvailable)
            row(for: .builtIn, subtitle: builtInSubtitle, enabled: builtInAvailability.isAvailable)

            statusAndAction
        } header: {
            Text("隧道")
        } footer: {
            Text("选择设备连接方式.切换后，依赖隧道的功能都按此方式取设备地址.")
        }
        .task {
            // 同步判定「不确定」时，异步实测一次（只可能把结果升级为可用）.
            builtInAvailability = await BuiltInTunnel.resolvedAvailability()
        }
    }

    // MARK: - 行

    /// 单条可选行：单选圆点 + 标题 + 一行说明. 无权限 / 未安装的行传 `enabled: false` ⇒ 置灰不可点.
    @ViewBuilder
    private func row(for kind: TunnelKind, subtitle: String, enabled: Bool = true) -> some View {
        Button {
            select(kind)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected(kind) ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected(kind) ? AppTheme.accent : Color.secondary)
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.body)
                        .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            // 整行可点（含右侧空白），不只命中圆点与文字.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - 状态与动作

    /// 当前方式的连接状态 + 动作按钮（`TintedButtonStyle`，不用纯蓝实底）.
    @ViewBuilder
    private var statusAndAction: some View {
        let kind = selectedKind
        let enabled = availability(for: kind).isAvailable
        VStack(alignment: .leading, spacing: 8) {
            Text(statusLine(kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle(kind)) {
                Task { await runAction(kind) }
            }
            .buttonStyle(TintedButtonStyle())
            .disabled(!enabled)
        }
        .padding(.vertical, 2)
    }

    private var selectedKind: TunnelKind {
        TunnelKind(rawValue: kindRaw) ?? .localDevVPN
    }

    private func isSelected(_ kind: TunnelKind) -> Bool {
        selectedKind == kind
    }

    /// 某方式的可用性. 内置隧道用异步复核后的缓存值，其余取实现的同步判定.
    private func availability(for kind: TunnelKind) -> TunnelAvailability {
        kind == .builtIn ? builtInAvailability : TunnelManager.provider(for: kind).availability
    }

    /// Shadowrocket 行说明：可用时给通用定位说明，不可用时直接给「为什么灰」（未安装）.
    private var shadowrocketSubtitle: String {
        TunnelManager.provider(for: .shadowrocket).availability.reason ?? TunnelKind.shadowrocket.detail
    }

    /// 内置隧道说明：直接给可用性结论（本版本恒为「暂未提供 + 签名权限现状」，见 `BuiltInTunnel.availability`）.
    private var builtInSubtitle: String {
        builtInAvailability.reason ?? "当前签名含 VPN 权限，可开启内置隧道."
    }

    private func statusLine(_ kind: TunnelKind) -> String {
        switch kind {
        case .localDevVPN:
            let connected = TunnelManager.provider(for: .localDevVPN).isConnected
            // 「检测到隧道接口」≠「连上了目标隧道」：判据只查本机有没有 utun（见 LocalDevVPN.isConnected）.
            return connected
                ? "连接状态：检测到本机存在隧道接口，不保证是 LocalDevVPN 的目标隧道."
                : "连接状态：未检测到隧道接口，请先在 LocalDevVPN 里连接."
        case .shadowrocket:
            return "无法探测连接状态.此方式仅作为跳转目标，不保证能提供设备连接."
        case .builtIn:
            // 这里判定的是签名里的权限，与 VPN 开关无关 —— 文案写明「当前签名」，避免被读成连接状态.
            let state = builtInAvailability.reason ?? "当前签名含 VPN 权限，可开启内置隧道."
            return state + "该判定来自当前签名，与 VPN 是否已连接无关."
        }
    }

    private func actionTitle(_ kind: TunnelKind) -> String {
        switch kind {
        case .localDevVPN: return "打开 LocalDevVPN"
        case .shadowrocket: return "打开 Shadowrocket"
        case .builtIn:
            return TunnelManager.provider(for: .builtIn).isConnected ? "断开内置隧道" : "开启内置隧道"
        }
    }

    // MARK: - 行为

    private func select(_ kind: TunnelKind) {
        // 无权限 / 未安装的行本身已 disabled，这里再兜一次（防程序化触发）.
        guard availability(for: kind).isAvailable else { return }
        let previous = selectedKind
        kindRaw = kind.rawValue
        // 离开内置隧道时顺手断开，避免隧道继续挂着.
        if previous == .builtIn, kind != .builtIn {
            Task { await TunnelManager.provider(for: .builtIn).stop() }
        }
        // 选中即触发该方式的首个动作（跳转 / 开启）；LocalDevVPN 需用户在该应用内连接，无需动作.
        switch kind {
        case .shadowrocket, .builtIn:
            Task { await TunnelManager.provider(for: kind).start() }
        case .localDevVPN:
            break
        }
    }

    private func runAction(_ kind: TunnelKind) async {
        let provider = TunnelManager.provider(for: kind)
        if kind == .builtIn, provider.isConnected {
            await provider.stop()
        } else {
            await provider.start()
        }
        if kind == .builtIn { builtInAvailability = await BuiltInTunnel.resolvedAvailability() }
    }
}
