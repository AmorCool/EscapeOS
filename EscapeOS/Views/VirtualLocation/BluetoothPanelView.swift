import CoreLocation
import SwiftUI

/// 蓝牙位置模拟面板（虚拟定位的辅助功能，默认关闭）.
struct BluetoothPanelView: View {
    @ObservedObject private var coordinator = BLECoordinator.shared
    @ObservedObject private var session = SpoofSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var role: BluetoothLinkRole = .broadcaster
    @State private var enabled = false
    @State private var hint: String?

    private static let roleKey = "escape.bluetoothRole"

    var body: some View {
        NavigationStack {
            List {
                usageSection
                roleSection
                if role == .receiver {
                    nearbySection
                }
                linkSection
                reportSection
            }
            .navigationTitle("蓝牙位置模拟")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert(requestTitle, isPresented: requestBinding) {
                Button("允许") { coordinator.approvePendingConnection() }
                Button("拒绝", role: .cancel) { coordinator.denyPendingConnection() }
            }
            .onAppear {
                enabled = coordinator.isActive
                if let saved = UserDefaults.standard.string(forKey: Self.roleKey),
                   let stored = BluetoothLinkRole(rawValue: saved) {
                    role = stored
                }
            }
            .onChange(of: enabled) { _, isOn in
                if isOn {
                    UserDefaults.standard.set(role.rawValue, forKey: Self.roleKey)
                    BluetoothSpoofBridge.shared.attach()
                    coordinator.start(role: role)
                } else {
                    coordinator.stop()
                    BluetoothSpoofBridge.shared.detach()
                }
            }
        }
    }

    // MARK: - 使用说明

    private var usageSection: some View {
        Section {
            Text("两台设备各装本 App：A 机选「模拟终端」，B 机选「信号端」。")
            Text("B 机在「附近设备」里点 A 机，A 机弹窗点「允许」后开始应用坐标。")
            Text("双方需保持 App 在前台。")
            Text("蓝牙为可选的跨设备扩展；单机无需第二台设备，直接用上方虚拟定位。")
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 角色与开关

    private var roleSection: some View {
        Section("角色与开关") {
            Picker("角色", selection: $role) {
                ForEach(BluetoothLinkRole.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(enabled)

            Toggle("启用蓝牙链路", isOn: $enabled)
                .disabled(role == .receiver && !session.hasPairing)

            if role == .receiver && !session.hasPairing {
                Text("信号端需要配对文件才能应用坐标。")
                    .foregroundStyle(LocusTheme.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 附近设备

    private var nearbySection: some View {
        Section("附近设备") {
            if coordinator.nearby.isEmpty {
                Text(enabled ? "未发现设备" : "打开开关后开始扫描")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.nearby) { peer in
                    Button {
                        hint = nil
                        coordinator.connect(to: peer.id)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.displayName)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(peer.roleText) · \(peer.rssi) dBm")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if peer.id == coordinator.connectedPeerID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(LocusTheme.statusGood)
                            }
                        }
                    }
                    .disabled(coordinator.connectedPeerID != nil)
                }

                Button {
                    coordinator.rescan()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - 链路状态

    private var linkSection: some View {
        Section("链路状态") {
            infoRow("状态", coordinator.state.label, tint: stateColor)
            infoRow("角色", role.title)
            infoRow("本机标识", BluetoothLink.displayName(for: role))
            if let peer = coordinator.peerName {
                infoRow("对端", peer)
            }
            if let sent = coordinator.lastSent {
                infoRow("最后下发", coordinateText(sent))
            }
            if role == .receiver {
                infoRow("本机模拟", session.status.label)
            }

            if role == .broadcaster {
                Button {
                    hint = BluetoothSpoofBridge.shared.pushCurrentPin() ? nil : "请先在地图上放置图钉。"
                } label: {
                    Label("立即下发图钉坐标", systemImage: "location.fill")
                }
                .disabled(!enabled || session.pin == nil)
            }

            if let hint = hint {
                Text(hint)
                    .foregroundStyle(LocusTheme.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = coordinator.lastError {
                Text(error)
                    .foregroundStyle(LocusTheme.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 回报与日志

    private var reportSection: some View {
        Section("回报与日志") {
            infoRow("状态回报", reportText)

            if coordinator.log.isEmpty {
                Text("暂无记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.log, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    coordinator.clearLog()
                } label: {
                    Label("清空日志", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 辅助

    private var requestBinding: Binding<Bool> {
        Binding(
            get: { coordinator.pendingRequest != nil },
            set: { _ in }
        )
    }

    private var requestTitle: String {
        "\(coordinator.pendingRequest?.displayName ?? "设备") 请求连接"
    }

    private var reportText: String {
        if role == .broadcaster {
            return coordinator.lastReport?.label ?? "暂无"
        }
        return BluetoothStatusReport.from(
            status: session.status,
            hasError: session.lastError != nil
        ).label
    }

    private var stateColor: Color {
        switch coordinator.state {
        case .off: return .primary.opacity(0.55)
        case .advertising, .scanning, .connecting: return LocusTheme.statusWarn
        case .connected, .synced: return LocusTheme.statusGood
        }
    }

    /// 键值行：键固定 76pt 等宽前导，值左对齐可换行（避免各行参差与省略号）.
    private func infoRow(_ key: String, _ value: String, tint: Color? = nil) -> some View {
        LabeledContent {
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(tint ?? .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Text(key)
                .frame(width: 76, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}
