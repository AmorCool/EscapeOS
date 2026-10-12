import CoreLocation
import SwiftUI

/// 蓝牙位置模拟面板（虚拟定位的辅助功能，默认关闭）.
///
/// ## v0.3.546 的两处改动（按用户反馈）
///
/// 1. **「停止蓝牙模拟」是独立动作**，不等于关面板。
///    之前只有顶部那个 `Toggle` 能停，用户的理解是「关掉面板 = 结束」会被动停掉，
///    但事实上面板一关链路还在跑（链路跟随开关，不跟随 sheet 生命周期）——
///    开关与面板混在一起，谁都说不清「现在到底停没停」。
///    现在把「启用 / 停止」做成两个**显式按钮**：停止就是不依赖面板、不依赖开关状态的
///    一键动作，随时可点，点完立刻断链路 + 解绑桥接。
///
/// 2. **精简**：原来的「使用说明」6 条文字、「链路状态」6 行键值、「回报与日志」
///    全量列表，加起来一屏装不下，用户评价「太复杂不友好」。
///    现在拆成：`状态`（一个胶囊 + 启停按钮）/ `角色`（选择器，仅未启用时可改）/
///    `附近设备`（仅信号端）/ `更多`（下发、重扫、重广播收进这一组）/ 日志**只留入口**。
///    详细日志与排查信息全部移到独立的日志页，主面板不再承担阅读日志的职责。
struct BluetoothPanelView: View {
    @ObservedObject private var coordinator = BLECoordinator.shared
    @ObservedObject private var session = SpoofSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var role: BluetoothLinkRole = .broadcaster
    @State private var hint: String?
    @State private var showLog = false

    private static let roleKey = "escape.bluetoothRole"

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if !coordinator.isActive {
                    roleSection
                    if role == .receiver && !session.hasPairing {
                        pairingNoticeSection
                    }
                }
                if coordinator.isActive && role == .receiver {
                    nearbySection
                }
                if coordinator.isActive {
                    actionsSection
                }
                logEntrySection
            }
            .navigationTitle("蓝牙位置模拟")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showLog) {
                BluetoothLogView()
            }
            .alert(requestTitle, isPresented: requestBinding) {
                Button("允许") { coordinator.approvePendingConnection() }
                Button("拒绝", role: .cancel) { coordinator.denyPendingConnection() }
            }
            .onAppear {
                if let saved = UserDefaults.standard.string(forKey: Self.roleKey),
                   let stored = BluetoothLinkRole(rawValue: saved) {
                    role = stored
                }
            }
        }
    }

    // MARK: - 状态与启停

    private var statusSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(coordinator.isActive ? coordinator.state.label : "未启用")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if coordinator.isActive {
                    Text(role.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if coordinator.isActive {
                Button(role: .destructive) {
                    stopSpoof()
                } label: {
                    Label("停止蓝牙模拟", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    startSpoof()
                } label: {
                    Label("启用蓝牙模拟", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(role == .receiver && !session.hasPairing)
            }

            if let error = coordinator.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(LocusTheme.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text(coordinator.isActive
                 ? "停止后链路立即断开，两台设备的坐标同步随之中止."
                 : "两台设备各装本 App：A 机选「模拟终端」，B 机选「信号端」.")
        }
    }

    // MARK: - 角色

    private var roleSection: some View {
        Section("角色") {
            Picker("角色", selection: $role) {
                ForEach(BluetoothLinkRole.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: role) { _, newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.roleKey)
            }
        }
    }

    private var pairingNoticeSection: some View {
        Section {
            Text("信号端需要配对文件才能应用坐标，请先在「设置」里导入.")
                .font(.caption)
                .foregroundStyle(LocusTheme.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 附近设备（信号端）

    private var nearbySection: some View {
        Section("附近设备") {
            if coordinator.nearby.isEmpty {
                Text("未发现设备")
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
            }
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        Section {
            // v0.3.540：两种角色都能「主动推当前图钉」——
            // A 机是下发，B 机是请求下发（走的都是各自那一条链路）。
            Button {
                hint = BluetoothSpoofBridge.shared.pushCurrentPin() ? nil : "请先在地图上放置图钉."
            } label: {
                Label(role == .broadcaster ? "立即下发图钉坐标" : "用本机图钉定位",
                      systemImage: "location.fill")
            }
            .disabled(session.pin == nil)

            if role == .receiver {
                Button {
                    coordinator.rescan()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
            }

            if role == .broadcaster && coordinator.hasDeniedPeers {
                Button {
                    coordinator.resumeAdvertising()
                } label: {
                    Label("重新开始广播", systemImage: "arrow.clockwise")
                }
            }

            if let hint = hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(LocusTheme.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("操作")
        } footer: {
            if let sent = coordinator.lastSent {
                Text("最后下发 \(coordinateText(sent))")
            }
        }
    }

    // MARK: - 日志入口

    private var logEntrySection: some View {
        Section {
            Button {
                showLog = true
            } label: {
                HStack {
                    Label("查看蓝牙日志", systemImage: "doc.text.magnifyingglass")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text("蓝牙日志独立存储，不与登录 / 商店等其它日志混在一起.")
        }
    }

    // MARK: - 动作

    private func startSpoof() {
        UserDefaults.standard.set(role.rawValue, forKey: Self.roleKey)
        BluetoothSpoofBridge.shared.attach()
        coordinator.start(role: role)
    }

    /// 一键停止（用户明确要求：不要「关面板 = 结束」这种隐式语义）.
    private func stopSpoof() {
        hint = nil
        coordinator.stop()
        BluetoothSpoofBridge.shared.detach()
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

    private var stateColor: Color {
        guard coordinator.isActive else { return .primary.opacity(0.55) }
        switch coordinator.state {
        case .off: return .primary.opacity(0.55)
        case .advertising, .scanning, .connecting, .suspended: return LocusTheme.statusWarn
        case .connected, .synced: return LocusTheme.statusGood
        }
    }

    private func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}
