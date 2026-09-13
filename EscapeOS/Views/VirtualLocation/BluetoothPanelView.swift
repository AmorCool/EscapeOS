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
                roleSection
                linkSection
                reportSection
            }
            .navigationTitle("蓝牙位置模拟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
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

    // MARK: - 一、角色与开关

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

            Text("双方都要保持在前台。")
                .foregroundStyle(.secondary)

            if role == .receiver && !session.hasPairing {
                Text("信号端需要配对文件才能应用坐标。")
                    .foregroundStyle(LocusTheme.statusWarn)
            }
        }
    }

    // MARK: - 二、链路状态

    private var linkSection: some View {
        Section("链路状态") {
            LabeledContent("状态") {
                Text(coordinator.state.label)
                    .foregroundStyle(stateColor)
            }
            LabeledContent("角色", value: role.title)
            if let peer = coordinator.peerName {
                LabeledContent("对端", value: peer)
            }
            if let sent = coordinator.lastSent {
                LabeledContent("最后下发", value: coordinateText(sent))
            }

            if role == .broadcaster {
                Button("立即下发图钉坐标") {
                    hint = BluetoothSpoofBridge.shared.pushCurrentPin() ? nil : "请先在地图上放置图钉。"
                }
                .disabled(!enabled || session.pin == nil)
            } else {
                LabeledContent("本机模拟", value: session.status.label)
            }

            if let hint {
                Text(hint)
                    .foregroundStyle(LocusTheme.statusWarn)
            }

            if let error = coordinator.lastError {
                Text(error)
                    .foregroundStyle(LocusTheme.statusBad)
            }
        }
    }

    // MARK: - 三、回报与日志

    private var reportSection: some View {
        Section("回报与日志") {
            LabeledContent("状态回报", value: reportText)

            if coordinator.log.isEmpty {
                Text("暂无记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.log, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Button("清空日志") { coordinator.clearLog() }
            }
        }
    }

    // MARK: - 辅助

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

    private func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}
