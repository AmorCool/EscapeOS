import SwiftUI

/// v0.3.207：百宝箱面板 —— 主页原生 sheet 呈现（presentationDetents 0.4↔1.0），
/// 系统上拉展开/下拉关闭，跟手流畅.内含杂七杂八工具的入口集合.
///
/// v0.3.328：**移除监督模式（Supervision）与 Wi-Fi 射频开关**。
/// - 监督模式：需要把设备置为受监督并自造 Escalate 身份，设备侧只认「当初监督它的那份身份」，
///   非越狱环境无解；已整块移除（含 SupervisionService）。
/// - Wi-Fi 射频：唯一可行通道是 MCInstall `SetWiFiPowerState`，而它**必须走监督通道**
///   （无监督 → 14005 `Unable to set Wi-Fi power`）。既然坚持不走监督那套，该开关已移除。
/// - 保留「局域网 Wi-Fi 配对连接」：走 lockdown `com.apple.mobile.wireless_lockdown`
///   `EnableWifiConnections`，无需监督、真实可用。
/// - 新增「开发者模式」：状态读 lockdown `DeveloperModeStatus`（com.apple.security.mac.amfi），
///   开启走 RSD amfi 服务；**系统未提供远程关闭接口**，关闭需去设备设置里手动关。
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
                    deviceControlCard
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

    // MARK: - 设备控制

    /// 开发者模式（iDescriptor 同款数据源 + amfi 开启）
    @State private var devModeOn = false
    @State private var devModeUnknown = true     // true=读不到（隧道未连），显示未知而不是「已关闭」
    @State private var devModeBusy = false
    @State private var devModeMsg: String?
    @State private var devModeMsgIsError = false

    /// 局域网 Wi-Fi 配对连接（lockdown EnableWifiConnections，免监督）
    @State private var wifiPairingOn = false
    @State private var wifiPairingUnknown = true
    @State private var wifiPairingBusy = false
    @State private var wifiPairingMsg: String?
    @State private var wifiPairingMsgIsError = false

    private func refreshDeviceStates() {
        Task.detached(priority: .utility) {
            let dev = DeveloperModeService.status()
            let pairing = WirelessLockdownService.readWifiConnectionsEnabled()
            await MainActor.run {
                if let dev {
                    devModeOn = dev
                    devModeUnknown = false
                } else {
                    devModeUnknown = true
                }
                if let pairing {
                    wifiPairingOn = pairing
                    wifiPairingUnknown = false
                } else {
                    wifiPairingUnknown = true
                }
            }
        }
    }

    private func setDeveloperMode(_ on: Bool) {
        guard !devModeBusy else { return }
        // 关闭：系统没有远程接口（amfi 只有 reveal/enable/accept/status），如实说明并弹回
        guard on else {
            devModeMsgIsError = true
            devModeMsg = "开发者模式无法远程关闭，请在设备「设置 → 隐私与安全性 → 开发者模式」里关闭"
            return
        }
        devModeBusy = true
        devModeMsg = nil
        devModeMsgIsError = false
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do { try DeveloperModeService.enable() }
            catch { failure = error.localizedDescription }
            let errText = failure
            // 以设备读回为准
            let readBack = DeveloperModeService.status()
            await MainActor.run {
                devModeBusy = false
                if let errText {
                    devModeMsgIsError = true
                    devModeMsg = "失败：\(errText)"
                }
                if let readBack {
                    devModeOn = readBack
                    devModeUnknown = false
                }
                if errText == nil {
                    devModeMsgIsError = !(readBack ?? false)
                    devModeMsg = readBack == true
                        ? "开发者模式已开启"
                        : "已下发开启，设备可能要求在「设置 → 隐私与安全性 → 开发者模式」确认并重启后生效"
                }
            }
        }
    }

    private func setWifiPairing(_ on: Bool) {
        guard !wifiPairingBusy else { return }
        wifiPairingBusy = true
        wifiPairingMsg = nil
        wifiPairingMsgIsError = false
        Task.detached(priority: .userInitiated) {
            var confirmed: Bool?
            var failure: String?
            do {
                // 一次操作只建一条隧道：写入 + 读回在同一条隧道内完成
                confirmed = try WirelessLockdownService.setWifiConnections(enabled: on)
            } catch {
                failure = error.localizedDescription
            }
            let errText = failure
            let readBack = confirmed
            await MainActor.run {
                wifiPairingBusy = false
                if let errText {
                    wifiPairingMsgIsError = true
                    wifiPairingMsg = "失败：\(errText)"
                    return
                }
                if let readBack {
                    wifiPairingOn = readBack
                    wifiPairingUnknown = false
                    wifiPairingMsgIsError = readBack != on
                    wifiPairingMsg = readBack == on
                        ? "已\(on ? "启用" : "停用")局域网 Wi-Fi 配对连接（设备已确认）"
                        : "写入已接受，但设备读回 \(readBack ? "开启" : "关闭")，可能被系统还原"
                } else {
                    wifiPairingOn = on
                    wifiPairingUnknown = false
                    wifiPairingMsgIsError = false
                    wifiPairingMsg = "已\(on ? "启用" : "停用")局域网 Wi-Fi 配对连接（设备未回读确认）"
                }
            }
        }
    }

    private var deviceControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设备控制").font(.headline).padding(.bottom, 2)

            Toggle(isOn: Binding(
                get: { devModeOn },
                set: { on in
                    guard !devModeBusy else { return }
                    setDeveloperMode(on)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("开发者模式", systemImage: "hammer").font(.subheadline)
                    Text(devModeUnknown
                         ? "状态未知（连接 LocalDevVPN + 配对文件后自动读取）"
                         : (devModeOn ? "已开启" : "已关闭 · 打开后设备可能要求重启"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(devModeBusy)

            Toggle(isOn: Binding(
                get: { wifiPairingOn },
                set: { on in
                    guard !wifiPairingBusy else { return }
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
            .disabled(wifiPairingBusy)

            if devModeBusy || wifiPairingBusy {
                HStack { ProgressView().controlSize(.small); Text("正在执行…").font(.caption).foregroundStyle(.secondary) }
            }
            if let msg = devModeMsg {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(devModeMsgIsError ? Color.red : Color.green)
            }
            if let msg = wifiPairingMsg {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(wifiPairingMsgIsError ? Color.red : Color.green)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .onAppear(perform: refreshDeviceStates)
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
