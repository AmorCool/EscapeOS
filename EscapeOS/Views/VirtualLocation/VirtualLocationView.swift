import SwiftUI
import NetworkExtension

/// 虚拟定位主入口页（移植自 locus-ZH）：
/// 地图 + 状态栏 + 底部控制台 + 收藏 / 设置。
///
/// 保活说明：会话是全局单例（SpoofSession.shared），返回「更多」菜单后
/// 模拟注入与定时器继续运行；退到后台由静音音频保活（KeepAliveManager）
/// 与后台定位延续。
struct VirtualLocationView: View {
    @ObservedObject private var session = SpoofSession.shared
    @State private var showSettings = false
    @State private var showPlaces = false

    var body: some View {
        ZStack(alignment: .bottom) {
            MapHomeView()

            BottomControlsView(
                showSettings: $showSettings,
                showPlaces: $showPlaces
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .navigationTitle("虚拟定位")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings) {
            VirtualLocationSettingsView()
        }
        .sheet(isPresented: $showPlaces) {
            PlacesView()
        }
        .alert("虚拟定位", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("确定", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }
}

/// 顶部状态条：模拟状态 / 配对缺失 / LocalDevVPN 未连接。
struct StatusBarView: View {
    @ObservedObject private var session = SpoofSession.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var tunnelConnected = LocalDevVPN.isConnected
    @State private var showSettings = false

    private enum Display {
        case notSpoofing
        case noPairing
        case connectVPN
        case status(String)
    }

    private var display: Display {
        switch session.status {
        case .idle:
            if !session.hasPairing {
                return .noPairing
            }
            return tunnelConnected ? .notSpoofing : .connectVPN
        case .connecting:
            return .status("正在连接…")
        case .active:
            return .status("正在模拟定位")
        case .reconnecting:
            return .status("正在重新连接…")
        case .dropped(let reason):
            return .status(reason.isEmpty ? "连接已断开" : "连接已断开 — \(reason)")
        }
    }

    private var color: Color {
        switch display {
        case .notSpoofing:
            return Color.primary.opacity(0.55)
        case .noPairing, .connectVPN:
            return LocusTheme.statusWarn
        case .status:
            switch session.status {
            case .active: return LocusTheme.statusGood
            case .connecting, .reconnecting: return LocusTheme.statusWarn
            case .dropped: return LocusTheme.statusBad
            case .idle: return Color.primary.opacity(0.55)
            }
        }
    }

    private var title: String {
        switch display {
        case .notSpoofing: return "未模拟定位"
        case .noPairing: return "未导入配对文件"
        case .connectVPN: return "连接 LocalDevVPN"
        case .status(let text): return text
        }
    }

    var body: some View {
        Group {
            if case .noPairing = display {
                Button { showSettings = true } label: {
                    statusContent
                }
                .buttonStyle(.plain)
            } else if case .connectVPN = display {
                Button(action: LocalDevVPN.openOrInstall) {
                    statusContent
                }
                .buttonStyle(.plain)
            } else {
                statusContent
            }
        }
        .sheet(isPresented: $showSettings) {
            VirtualLocationSettingsView()
        }
        .onAppear { refreshTunnel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshTunnel() }
        }
        .onChange(of: session.status) { _, _ in
            refreshTunnel()
        }
        .onChange(of: session.hasPairing) { _, _ in
            refreshTunnel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            // LocalDevVPN 的连接变化会广播到这里（即使不是我们拥有的 VPN）。
            refreshTunnel()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refreshTunnel()
            }
        }
    }

    private var statusContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if case .noPairing = display {
                Image(systemName: "person.badge.key.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.accent)
            } else if case .connectVPN = display {
                Image(systemName: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.accent)
            } else if case .active = session.status, let sim = session.simulated {
                Text(String(format: "%.4f, %.4f", sim.latitude, sim.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func refreshTunnel() {
        tunnelConnected = LocalDevVPN.isConnected
    }
}

/// 底部控制台：出行方式 / 设置 / 收藏 / 摇杆 / 轨迹 / 开始与停止定位。
struct BottomControlsView: View {
    @ObservedObject private var session = SpoofSession.shared
    @Binding var showSettings: Bool
    @Binding var showPlaces: Bool

    private let trayShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        VStack(spacing: 12) {
            if session.joystickActive {
                JoystickPad { vector in
                    session.updateJoystick(vector: vector)
                }
                .frame(width: 148, height: 148)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if session.routeActive || session.routePaused {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Button { session.adjustSpeed(by: -0.25) } label: {
                            Label("减速", systemImage: "minus.circle.fill")
                        }
                        .disabled(session.speedMultiplier <= 0.25)

                        Spacer()
                        VStack(spacing: 2) {
                            Text(String(format: "%.2fx · %.1f 公里/小时", session.speedMultiplier, session.travelMode.baseSpeed * session.speedMultiplier * 3.6))
                                .font(.subheadline.bold())
                                .monospacedDigit()
                            Text("第 \(max(1, session.routeLap)) 圈 · \(Int(session.routeProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button { session.adjustSpeed(by: 0.25) } label: {
                            Label("加速", systemImage: "plus.circle.fill")
                        }
                        .disabled(session.speedMultiplier >= 4.0)
                    }
                    .buttonStyle(.borderless)

                    ProgressView(value: session.routeProgress)
                        .tint(LocusTheme.accent)
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 8) {
                ForEach(TravelMode.allCases) { mode in
                    let selected = session.travelMode == mode
                    Button {
                        session.travelMode = mode
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(selected ? .black : .primary)
                            .frame(width: 44, height: 40)
                            .background(
                                Capsule().fill(selected ? LocusTheme.accent : Color.primary.opacity(0.08))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                trayIcon("gearshape.fill") { showSettings = true }
                trayIcon("star.fill") { showPlaces = true }

                Button {
                    if session.joystickActive {
                        session.stopJoystick()
                    } else {
                        session.startJoystick()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                        Text(session.joystickActive ? "摇杆开启" : "摇杆")
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.joystickActive ? .black : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(session.joystickActive ? LocusTheme.accentSecondary : Color.primary.opacity(0.08))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                if session.isSpoofing {
                    if session.canResumeRoute {
                        Button {
                            session.resumeRoute()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.body.bold())
                                .foregroundStyle(.black)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(LocusTheme.accent))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("继续轨迹")
                    }
                    Button {
                        session.stop()
                    } label: {
                        Text(session.isMoving ? "暂停" : "停止定位")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 72)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                            .background(Capsule().fill(LocusTheme.danger))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        guard let pin = session.pin else {
                            session.lastError = "请先点击地图放置图钉。"
                            return
                        }
                        session.teleport(to: pin)
                    } label: {
                        Text("开始定位")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(minWidth: 96)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 10)
                            .background(Capsule().fill(LocusTheme.accent))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isBusy)
                }
            }
        }
        .padding(14)
        .locusGlass(.regular, in: trayShape)
        // 整个托盘吸收点击，避免误触穿透到地图。
        .contentShape(trayShape)
    }

    private func trayIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
