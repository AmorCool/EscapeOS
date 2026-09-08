import SwiftUI

/// v0.3.207：百宝箱面板 —— 主页原生 sheet 呈现（presentationDetents 0.4↔1.0），
/// 系统上拉展开/下拉关闭，跟手流畅.内含杂七杂八工具的入口集合.
struct TreasureBoxView: View {
    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题区（sheet 拖动指示条由 presentationDragIndicator 提供）
            // v0.3.208：拖动指示条与"百宝箱"文字挨太近 → 加 padding 撑开
            Text("百宝箱")
                .font(.headline)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 12) {
                    heroCard
                    wifiPowerCard
                    itemsCard
                    Text("更多工具持续补充中")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemBackground))
    }

    private var heroCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.title2)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("百宝箱")
                    .font(.title3.weight(.semibold))
                Text("小工具集 · 持续补充")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // v0.3.240：WiFi 射频开关 + 局域网 Wi-Fi 配对连接
    //（v0.3.244 起走 WirelessLockdownService：射频 = MCInstall SetWiFiPowerState
    //（pmd3 profile set-wifi-power 同款）；配对连接 = lockdown SetValue + GetValue
    // 状态读回（iDescriptor 同款数据源））
    // v0.3.244 修复：此前 wifiPairingOn 从未赋值——Toggle 弹回、永远显示关、
    // 永远无法触达「停用」路径（用户实测"能开启但开关很快关闭、无法关闭"）。
    @State private var wifiPowerOn = UserDefaults.standard.bool(forKey: WirelessLockdownService.wifiPowerStateKey)
    @State private var wifiPairingOn = false
    @State private var wifiPairingUnknown = true   // true=状态读不到（隧道未连），显示未知
    @State private var wifiPowerBusy = false
    @State private var wifiPowerMsg: String?

    // 出现时读回设备真实状态（射频持久化值在 @State 初始化时已恢复；
    // EnableWifiConnections 无持久化，必须 GetValue 实时读）
    private func refreshWifiStates() {
        Task.detached(priority: .utility) {
            let enabled = WirelessLockdownService.readWifiConnectionsEnabled()
            await MainActor.run {
                if let enabled {
                    wifiPairingOn = enabled
                    wifiPairingUnknown = false
                } else {
                    wifiPairingUnknown = true
                }
            }
        }
    }

    private func setWifiPower(_ on: Bool) {
        wifiPowerBusy = true
        wifiPowerMsg = nil
        Task.detached(priority: .userInitiated) {
            do {
                try WirelessLockdownService.setWifiPower(on)
                await MainActor.run {
                    wifiPowerBusy = false
                    wifiPowerOn = on
                    wifiPowerMsg = "已\(on ? "开启" : "关闭") Wi-Fi 射频（设备已确认）"
                }
            } catch {
                await MainActor.run {
                    wifiPowerBusy = false
                    wifiPowerMsg = "失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func setWifiPairing(_ on: Bool) {
        wifiPowerBusy = true
        wifiPowerMsg = nil
        Task.detached(priority: .userInitiated) {
            do {
                if on {
                    try WirelessLockdownService.enableWifiConnections()
                } else {
                    try WirelessLockdownService.disableWifiConnections()
                }
                // v0.3.244：写成功后读回设备真实值确认（写成功≠生效，以设备为准）
                let confirmed = WirelessLockdownService.readWifiConnectionsEnabled()
                await MainActor.run {
                    wifiPowerBusy = false
                    if let confirmed {
                        wifiPairingOn = confirmed
                        wifiPairingUnknown = false
                        wifiPowerMsg = confirmed == on
                            ? "已\(on ? "启用" : "停用")局域网 Wi-Fi 配对连接（设备已确认）"
                            : "写入已接受，但设备读回 \(confirmed ? "开启" : "关闭")，可能被系统还原"
                    } else {
                        // 读回失败（隧道可能已被重置）——至少把 UI 状态跟手
                        wifiPairingOn = on
                        wifiPowerMsg = "已\(on ? "启用" : "停用")局域网 Wi-Fi 配对连接"
                    }
                }
            } catch {
                await MainActor.run {
                    wifiPowerBusy = false
                    wifiPowerMsg = "失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private var wifiPowerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设备控制").font(.headline).padding(.bottom, 2)
            Toggle(isOn: Binding(
                get: { wifiPowerOn },
                set: { on in
                    guard !wifiPowerBusy else { return }
                    setWifiPower(on)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi 射频开关").font(.subheadline)
                    Text("MCInstall SetWiFiPowerState（需 LocalDevVPN + 配对文件）；关闭后若 LocalDevVPN 走 Wi-Fi，隧道会断开，需恢复网络后重新开启")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(wifiPowerBusy)
            Toggle(isOn: Binding(
                get: { wifiPairingOn },
                set: { on in
                    guard !wifiPowerBusy else { return }
                    setWifiPairing(on)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("局域网 Wi-Fi 配对连接", systemImage: "wifi").font(.subheadline)
                    Text(wifiPairingUnknown
                         ? "当前状态未知（连接 LocalDevVPN + 配对文件后自动读取）"
                         : "当前状态：\(wifiPairingOn ? "开启" : "关闭")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(wifiPowerBusy)
            if wifiPowerBusy {
                HStack { ProgressView().controlSize(.small); Text("正在执行…").font(.caption).foregroundStyle(.secondary) }
            }
            if let msg = wifiPowerMsg {
                Text(msg).font(.caption2).foregroundStyle(wifiPowerMsg?.hasPrefix("失败") == true ? .red : .green)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .onAppear(perform: refreshWifiStates)
    }

    private var itemsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("工具")
                .font(.headline)
                .padding(.bottom, 6)
            ForEach(TreasureItem.placeholder) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("即将上线")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                Divider().opacity(item.id == TreasureItem.placeholder.last?.id ? 0 : 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

/// 百宝箱工具占位项（后续逐项实现并接真实页面）
struct TreasureItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let color: Color
    static let placeholder: [TreasureItem] = [
        .init(id: "1", icon: "doc.text.magnifyingglass", title: "设备日志导出",
              detail: "一键导出系统日志/Sysmon/诊断数据", color: .blue),
        .init(id: "2", icon: "key.fill", title: "随机设备 ID",
              detail: "重置 ApplePackage/Anisette 设备标识", color: .indigo),
        .init(id: "3", icon: "wifi", title: "设备网络信息",
              detail: "查看局域网 IP / 端口占用", color: .purple),
        .init(id: "4", icon: "trash", title: "清理应用残留",
              detail: "扫描并清理卸载残留的容器/缓存", color: .gray),
    ]
}
