import SwiftUI

/// v0.3.199：电池健康面板 —— diagnostics_relay IORegistry 读取（非越狱可读）.
/// 参考 iDescriptor BatteryInfo 面板：健康/循环/容量/序列号/充电/适配器.
/// v0.3.205：当前电量改百分比、新增适配器电源+电压卡、序列号小眼睛、厂商/生产日期.
struct BatteryHealthView: View {
    @State private var isLoading = true
    @State private var info: BatteryHealthInfo?
    @State private var errorText: String?
    @State private var lastUpdated: Date?
    /// v0.3.202：实时更新 —— 定时轮询（10s），离开页面取消
    @State private var pollTask: Task<Void, Never>?
    /// v0.3.205：序列号小眼睛 —— 默认隐藏，点眼睛显示
    @State private var showSerial = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading {
                    ProgressView("正在读取电池数据…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if let info {
                    healthRing(info: info)
                    metricsGrid(info: info)
                    adapterCard(info: info)      // v0.3.205：适配器电源 + 电压
                    lowPowerCard                 // v0.3.214：低电量模式（loupe 同款）
                    identityCard(info: info)     // v0.3.205：序列号(眼睛)/厂商/生产日期
                    if let lastUpdated {
                        Label("更新于 \(Self.timeFormatter.string(from: lastUpdated))", systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    rawCard(info: info)
                } else {
                    errorCard
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("电池健康")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await load()
            // v0.3.202：实时轮询 —— struct 不能 [weak self]，用 Task.isCancelled 守卫
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else { break }
                    await self.load(silent: true)
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }()

    private func load(silent: Bool = false) async {
        if !silent { isLoading = true }
        defer { if !silent { isLoading = false } }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try BatteryHealthService.fetchBatteryHealth()
            }.value
            info = result
            lastUpdated = Date()
            errorText = nil
        } catch {
            if !silent { errorText = error.localizedDescription }
        }
    }

    // MARK: 健康度环形
    private func healthRing(info: BatteryHealthInfo) -> some View {
        let health = info.healthPercent ?? 0
        let color: Color = health >= 85 ? .green : (health >= 70 ? .yellow : .orange)
        return VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(health) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.8), value: health)
                VStack(spacing: 2) {
                    Text("\(health)%")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .foregroundStyle(color)
                    Text("电池健康度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
            Text(healthLabel(health))
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// v0.3.286：对齐爱思评级（良好 / 一般 / 差）
    private func healthLabel(_ health: Int) -> String {
        switch health {
        case 80...: return "良好"
        case 60..<80: return "一般"
        default: return "差"
        }
    }

    // MARK: 指标网格
    private func metricsGrid(info: BatteryHealthInfo) -> some View {
        // v0.3.291：指标项与爱思「电池详情」对齐（充电次数 / 出厂容量 / 满充容量 / 电池寿命）
        let rows: [(String, String)] = [
            ("当前电量", info.currentPercent.map { "\($0)%" } ?? "—"),
            ("充电次数", info.cycleCount.map { "\($0) 次" } ?? "—"),
            ("出厂容量", info.designCapacity.map { "\($0) mAh" } ?? "—"),
            ("满充容量", info.maxCapacity.map { "\($0) mAh" } ?? "—"),
            ("电池寿命", info.healthPercent.map { "\($0)%" } ?? "—"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(rows, id: \.0) { row in
                VStack(spacing: 4) {
                    Text(row.1)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(row.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.tertiarySystemGroupedBackground))
                )
            }
        }
    }

    // MARK: v0.3.214 低电量模式卡（loupe 同款：ProcessInfo.isLowPowerModeEnabled）
    private var lowPowerCard: some View {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        return HStack(spacing: 12) {
            Image(systemName: "battery.25percent")
                .font(.title2)
                .foregroundStyle(lpm ? .yellow : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(lpm ? "低电量模式开启" : "低电量模式关闭")
                    .font(.subheadline.weight(.semibold))
                Text(lpm ? "系统正在省电，部分后台活动已暂停" : "正常用电模式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(lpm ? "开" : "关")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(lpm ? .yellow : .green)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: v0.3.205 适配器卡（电源 + 电压）
    private func adapterCard(info: BatteryHealthInfo) -> some View {
        let watts = info.adapterWatts.map { "\($0) W" } ?? "—"
        let volts = info.adapterVoltage.map { String(format: "%.1f V", $0) } ?? "—"
        let desc = info.adapterDescription
        return HStack(spacing: 12) {
            Image(systemName: "powerplug.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("适配器")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Label(watts, systemImage: "bolt.fill")
                        .font(.subheadline.weight(.semibold))
                    Label(volts, systemImage: "waveform.path.ecg")
                        .font(.subheadline.weight(.semibold))
                }
                if let desc, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: v0.3.205 身份卡（序列号小眼睛 / 厂商 / 生产日期）
    /// v0.3.286：身份与电芯参数卡（移植爱思「电池详情」右栏：厂商/生产日期/序列号/
    /// 出厂容量/当前容量/满充容量/当前电压/开机电压/电池电流/警告水平/临界水平）
    private func identityCard(info: BatteryHealthInfo) -> some View {
        VStack(spacing: 0) {
            // 序列号（眼睛切换）
            HStack(spacing: 12) {
                Image(systemName: "number.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text("电池序列号")
                    .font(.subheadline)
                Spacer()
                Text(showSerial ? (info.serial ?? "未知") : String(repeating: "•", count: min(info.serial?.count ?? 6, 10)))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(showSerial ? .primary : .secondary)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSerial.toggle() }
                } label: {
                    Image(systemName: showSerial ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 10)
            batteryCardRow("电池厂商", info.batteryManufacturer ?? "未知", icon: "hammer.fill")
            batteryCardRow("生产日期", manufactureDateText(info), icon: "calendar")
            batteryCardRow("出厂容量", info.designCapacity.map { "\($0) mAh" }, icon: "battery.0")
            batteryCardRow("当前容量", info.currentCapacityMAh.map { "\($0) mAh" }, icon: "battery.50")
            batteryCardRow("满充容量", info.maxCapacity.map { "\($0) mAh" }, icon: "battery.100")
            batteryCardRow("额定容量", info.nominalChargeCapacity.map { "\($0) mAh" }, icon: "battery.75")
            batteryCardRow("剩余容量", info.remainingCapacity.map { "\($0) mAh" }, icon: "battery.25")
            batteryCardRow("当前电压", info.voltage.map { String(format: "%.2f V", $0) }, icon: "bolt.fill")
            batteryCardRow("开机电压", info.bootVoltage.map { String(format: "%.2f V", $0) }, icon: "power")
            batteryCardRow("电池电流", info.instantAmperage.map { "\($0) mA" }, icon: "waveform.path.ecg")
            batteryCardRow("电池功率", info.batteryPowerMW.map { "\($0) mW" }, icon: "bolt.circle")
            batteryCardRow("电池温度", temperatureText(info), icon: "thermometer.medium")
            batteryCardRow("电池处于警告水平", warnLevelText(info), icon: "exclamationmark.triangle")
            batteryCardRow("电池处于临界水平", boolText(info.atCriticalLevel), icon: "exclamationmark.octagon")
        }
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// 电池温度：只取 `Temperature`（IOPMPowerSource）；iOS 27 已无该键 → 与爱思同样显示 `--`
    private func temperatureText(_ info: BatteryHealthInfo) -> String? {
        info.temperatureC.map { String(format: "%.1f ℃", $0) }
    }

    /// 电池是否处于警告水平：`AtWarnLevel`（idm_info.dll 读的同名键）.
    /// iOS 27 的 IOPMPowerSource 已无此键 —— 爱思本机也显示「否」，即键缺失按 false 处理，
    /// 这里与爱思保持同一口径（不用「系统未提供」占位）.
    private func warnLevelText(_ info: BatteryHealthInfo) -> String? {
        (info.atWarnLevel ?? false) ? "是" : "否"
    }

    /// 卡片行（带分隔线，与序列号行同款尺寸）
    private func batteryCardRow(_ label: String, _ value: String?, icon: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(value ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
        }
    }

    private func boolText(_ v: Bool?) -> String? {
        guard let v else { return nil }
        return v ? "是" : "否"
    }

    /// 生产日期：键序按 idm_info.dll 读的同名字段（`DateOfFirstUse` 等）.
    /// 旧系统能返回就直接显示；iOS 27 全 plane 已无该键 → 与爱思「设备详情」同一口径显示「未知」
    /// （爱思电池面板里那个日期不是设备值，是它自己服务端按序列号查的保修/启用时间）.
    private func manufactureDateText(_ info: BatteryHealthInfo) -> String? {
        let keys = ["DateOfFirstUse", "ManufactureDate", "ProductionDate", "ManufacturingDate"]
        for k in keys {
            if let d = info.raw[k] as? String, !d.isEmpty { return d }
            if let n = info.raw[k] as? Int, n > 0 { return String(n) }
        }
        if let bd = info.raw["BatteryData"] as? [String: Any] {
            for k in keys {
                if let d = bd[k] as? String, !d.isEmpty { return d }
            }
        }
        return "未知"
    }

    private func chargingLabel(_ info: BatteryHealthInfo) -> String {
        if info.fullyCharged == true { return "已充满" }
        if info.isCharging == true { return "充电中" }
        return "未充电"
    }

    // v0.3.251: 错误态拆成两张独立卡片 —— (1)状态卡(图标/标题/重试)
    // (2)配对引导卡(PairingGuideCard 自带独立卡片背景), 不再把引导挤进状态卡里.
    // v0.3.252：错误态两张卡片**同款紧凑样式**（图标块 + 文案 + 右侧重试，同一 16pt 圆角、
    // 同一 12pt 内边距、同一高度量级）——v0.3.251 状态卡用大图标+大按钮、引导卡用小行样式，
    // 两卡一大一小非常不协调（用户实测截图）.
    private var errorCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "battery.0percent",
                           tint: Color.secondary, symbolSize: 20, frameSize: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("无法读取电池数据")
                        .font(.subheadline.weight(.semibold))
                    if let err = errorText, !PairingGate.isPairingError(err) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Button("重试") {
                    Task { await load() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
            }
            .padding(16)
            .background(errorCardBackground)

            if let err = errorText, PairingGate.isPairingError(err) {
                // 独立卡片: 与全 App 其他功能页同一 PairingGuideCard 视觉
                PairingGuideCard(note: "电池健康还需要 LocalDevVPN 已连接（远程隧道读取）.",
                                 showChevron: true)
            }
        }
    }

    private var errorCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }

    /// 调试：原始字段（字段缺失时可排查 iOS 版本差异）
    private func rawCard(info: BatteryHealthInfo) -> some View {
        let keys = Array(info.raw.keys).sorted().prefix(14)
        return VStack(alignment: .leading, spacing: 6) {
            Text("原始数据")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(keys), id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(describing: info.raw[key] ?? "").prefix(40))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
