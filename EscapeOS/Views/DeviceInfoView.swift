import SwiftUI
import UIKit

/// v0.3.208：设备信息面板 —— iDescriptor 完整字段（基础/硬件/序列号/网络/存储）.
/// 序列号/UDID/IMEI/ECID/MLB 等敏感字段：统一小眼睛显示/隐藏 + 长按复制.
struct DeviceInfoView: View {
    @State private var info: DeviceInfoModel?
    @State private var errorText: String?
    @State private var loading = true
    /// 隐私敏感字段统一小眼睛状态（默认全部隐藏）
    @State private var showSensitive = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if loading {
                    ProgressView("正在读取设备信息…").frame(maxWidth: .infinity).padding(.vertical, 60)
                } else if let info {
                    // v0.3.294：分组与顺序对齐爱思「设备详情」
                    // v0.3.305：按实测通道补齐缺项（设备树 / 电池节点 / 全量 lockdown）
                    // （设备 → 系统与时区 → 卡槽与网络 → CPU 与硬件 → 电池 →
                    //   零部件 → 生产验机 → 存储 → 功能支持 → 原始数据）
                    deviceHero(info)
                    deviceSection(info)
                    systemSection(info)
                    networkSection(info)
                    hardwareSection(info)
                    batterySection(info)
                    Group {
                        partsSection(info)
                        productionSection(info)
                        storageSection(info)
                        featuresSection(info)
                        unavailableNote
                        allValuesSection(info)
                    }
                } else {
                    errorCard
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("设备信息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let info {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showSensitive.toggle() } label: {
                    // v0.3.221：图标=当前状态（显示中=睁眼，隐藏中=闭眼），修反逻辑
                    Image(systemName: showSensitive ? "eye" : "eye.slash")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            info = try await Task.detached(priority: .userInitiated) {
                try DeviceInfoService.collectFull()
            }.value
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func deviceHero(_ info: DeviceInfoModel) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3").font(.system(size: 42)).foregroundStyle(.blue)
            Text(info.deviceName ?? info.modelName).font(.title3.weight(.semibold))
            Text("\(info.productType) · iOS \(info.systemVersion)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    /// v0.3.305：设备（行序与分组对齐爱思「设备详情」第一组）
    ///
    /// 爱思行序：设备名称/容量颜色/上市日期 → 设备型号/激活状态/生产日期 →
    /// 序列号/越狱状态/销售类型 → 主板序列号/产品类型/销售型号 → ECID/固件版本/销售地区 → UDID
    private func deviceSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "设备", icon: "iphone.gen3") {
            row("设备名称", info.deviceName)
            row("容量颜色", capacityColorText(info))
            row("上市日期", info.releaseDate)
            row("设备型号", info.modelName)
            row("激活状态", activationText(info.activationState))
            row("生产日期", Self.notProvided)
            sensitiveRow("序列号", info.serialNumber)
            row("越狱状态", info.jailbroken.map { $0 ? "已越狱" : "未越狱" })
            row("销售类型", info.salesType)
            sensitiveRow("主板序列号", info.mlbSerial)
            row("产品类型", productTypeText(info))
            row("销售型号", [info.modelNumber, info.region].compactMap { $0 }.joined(separator: " "))
            sensitiveRow("ECID", info.ecid)
            row("固件版本", versionText(info))
            row("销售地区", [info.region, info.regionName].compactMap { $0 }.joined(separator: " "))
            sensitiveRow("UDID", info.udid)
            row("硬件型号", info.uniqueModel)
            row("设备类别", info.deviceClass)
        }
    }

    /// 容量 + 机身颜色（爱思显示「512GB 黑色」）.
    /// 容量用本机磁盘总容量；颜色名只在有实证映射时才翻译，否则显示设备给的颜色代码.
    private func capacityColorText(_ info: DeviceInfoModel) -> String? {
        guard info.storageTotalGB > 0 else { return nil }
        let cap = "\(info.storageTotalGB)GB"
        if let name = DeviceCatalog.deviceColorName(info.deviceColor) { return "\(cap) \(name)" }
        if let code = info.deviceColor, !code.isEmpty { return "\(cap)（颜色代码 \(code)）" }
        return cap
    }

    /// 「固件版本」= iOS 版本 (构建号) —— 与爱思同口径（爱思把 iOS 版本这一行叫「固件版本」）
    private func versionText(_ info: DeviceInfoModel) -> String? {
        guard let build = info.buildVersion, !build.isEmpty else { return info.systemVersion }
        return "\(info.systemVersion) (\(build))"
    }

    /// 产品类型：ProductType + 监管型号（如 iPhone15,4 (A2846)）
    private func productTypeText(_ info: DeviceInfoModel) -> String? {
        let pt = info.productType
        guard !pt.isEmpty else { return nil }
        if let reg = info.regulatoryModel, !reg.isEmpty { return "\(pt) (\(reg))" }
        return pt
    }

    private func activationText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "Activated": return "已激活"
        case "Unactivated", "FactoryActivated": return "未激活"
        default: return raw
        }
    }

    /// v0.3.305：系统与时区（对齐爱思第二组：时区/地区/24 小时制 + 充电次数/剩余电量/电池寿命）
    @ViewBuilder
    private func systemSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "系统与时区", icon: "gearshape.2.fill") {
            row("时区", info.timeZone)
            row("地区", info.localeRegion ?? info.region)
            row("24 小时制", info.uses24HourClock.map { $0 ? "是" : "否" })
            row("充电次数", info.cycleCount.map { "\($0) 次" })
            row("剩余电量", info.batteryLevel.map { "\($0)%" })
            row("电池寿命", batteryLifeText(info))
            row("iBoot 固件", info.firmwareVersion)
        }
    }

    /// 电池寿命：优先用读到的健康度，读不到就按爱思本机同款显示「系统未提供」
    private func batteryLifeText(_ info: DeviceInfoModel) -> String? {
        guard let h = info.batteryHealthPercent else { return Self.notProvided }
        return "\(h)%"
    }

    /// v0.3.305：CPU 与硬件（行序对齐爱思第四组）
    ///
    /// 爱思行序：CPU 类型/Wi-Fi 模块/屏幕大小 → CPU 核心/Wi-Fi 序列号/屏幕分辨率 →
    /// CPU 频率/无线技术类型/硬盘类型 → 协处理器/硬件版本/分区类型
    @ViewBuilder
    private func hardwareSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "CPU 与硬件", icon: "cpu") {
            row("CPU 类型", info.cpuName)
            row("Wi-Fi 模块", Self.notProvided)
            row("屏幕大小", info.screenInches.map { "\($0) 英寸" })
            row("CPU 核心", "\(info.cpuCount) 核")
            row("Wi-Fi 序列号", info.wirelessBoardSerial)
            row("屏幕分辨率", screenResolution)
            row("CPU 频率", info.cpuFrequency)
            row("无线技术类型", Self.notProvided)
            row("硬盘类型", info.diskCellType)
            row("协处理器", Self.notProvided)
            row("硬件版本", info.hardwareVersion)
            row("分区类型", info.partitionType)
            row("硬件型号", info.uniqueModel)
            row("硬件平台", info.hardwarePlatform)
            row("Wi-Fi 芯片", info.wifiChipset)
            row("物理内存", "\(info.memoryMB) MB")
            row("CPU 架构", info.cpuArchitecture)
        }
    }

    /// 屏幕分辨率（取设备实时值；UIScreen 需主线程）
    private var screenResolution: String? {
        let b = UIScreen.main.nativeBounds
        guard b.width > 0, b.height > 0 else { return nil }
        return "\(Int(max(b.width, b.height))) x \(Int(min(b.width, b.height)))"
    }

    /// v0.3.305：卡槽与网络（行序对齐爱思第三组）
    ///
    /// 爱思行序：卡槽类型/IMEI1/eSIM卡1 → 有无卡托/IMEI2/eSIM卡2 → 基带版本/Wi-Fi地址/SIM卡状态
    /// → 基带激活版本/蓝牙地址/SIM卡托状态 → 基带状态/蜂窝地址/通话功能 → 基带序列号/IMSI/协议版本
    @ViewBuilder
    private func networkSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "卡槽与网络", icon: "antenna.radiowaves.left.and.right") {
            row("卡槽类型", simSlotKind(info))
            sensitiveRow("IMEI 1", info.imei)
            row("eSIM 卡1 信息", info.carrier1)
            row("有无卡托", info.simTrayInserted.map { $0 ? "有" : "无" })
            sensitiveRow("IMEI 2", info.imei2)
            row("eSIM 卡2 信息", info.carrier2)
            row("基带版本", info.basebandVersion)
            row("Wi-Fi 地址", info.wiFiAddress)
            row("SIM 卡状态", info.simStatus)
            row("基带激活版本", info.basebandActivationTicket)
            row("蓝牙地址", info.bluetoothAddress)
            row("SIM 卡托状态", info.simTrayStatus)
            row("基带状态", info.basebandStatus)
            row("蜂窝地址", info.ethernetAddress)
            row("通话功能", info.callCapable.map { $0 ? "是" : "否" })
            sensitiveRow("基带序列号", info.basebandSerial)
            sensitiveRow("IMSI", info.imsi)
            row("协议版本", info.protocolVersion)
            row("基带芯片", info.basebandChipset)
            row("Wi-Fi 序列号", info.wirelessBoardSerial)
            sensitiveRow("ICCID", info.iccid)
            sensitiveRow("IMSI 2", info.imsi2)
            sensitiveRow("MEID", info.meid)
        }
    }

    /// 卡槽类型：由「SIM1/SIM2 是否 eSIM」推导（两张都内嵌 = 无实体卡槽）.
    /// 本机实测（iPhone15,4，SIM1IsEmbedded/SIM2IsEmbedded 均为 true）与爱思显示的「单卡」一致.
    private func simSlotKind(_ info: DeviceInfoModel) -> String? {
        guard let embedded = info.simsAreEmbedded else { return nil }
        return embedded ? "单卡" : "双卡"
    }

    private func storageSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "存储", icon: "internaldrive") {
            if let total = info.totalDiskBytes {
                row("总容量", formatBytes(total))
            }
            if let data = info.totalDataBytes {
                row("数据容量", formatBytes(data))
            }
            if let sys = info.totalSystemBytes {
                row("系统占用", formatBytes(sys))
            }
            row("本机可用 / 总", "\(info.storageFreeGB) GB / \(info.storageTotalGB) GB")
            // v0.3.293：硬盘详情（移植爱思同款面板——IORegistry AppleEmbeddedNVMeController）
            Divider().padding(.vertical, 6)
            NavigationLink {
                StorageDetailView()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive.fill").foregroundStyle(.blue)
                    Text("硬盘详情").font(.footnote)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// v0.3.285：电池卡（移植爱思电池面板——健康度/循环次数/容量/当前电量）
    /// v0.3.305：电池序列号/电压/电流/温度改由 AppleSmartBattery 节点补（iTunes 域在 iOS 27 已无这些键）
    @ViewBuilder
    private func batterySection(_ info: DeviceInfoModel) -> some View {
        if info.batteryHealthPercent != nil || info.cycleCount != nil || info.designCapacity != nil
            || info.batterySerial != nil {
            sectionCard(title: "电池", icon: "battery.100") {
                VStack(alignment: .leading, spacing: 8) {
                    if let health = info.batteryHealthPercent {
                        let tint: Color = health >= 80 ? .green : (health >= 60 ? .orange : .red)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(health)%")
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint)
                            Text("电池健康度")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(min(max(health, 0), 100)), total: 100)
                            .tint(tint)
                    }
                    row("循环次数", info.cycleCount.map { "\($0) 次" })
                    row("设计容量", info.designCapacity.map { "\($0) mAh" })
                    row("实际容量", info.maxCapacity.map { "\($0) mAh" })
                    row("当前电量", info.batteryLevel.map { "\($0)%" })
                    row("充电状态", chargingText(info))
                    row("电池型号", info.batteryModelID)
                    row("电池电压", info.batteryVoltageMV.map { String(format: "%.2f V", Double($0) / 1000.0) })
                    row("电池电流", info.batteryAmperageMA.map { "\($0) mA" })
                    row("电池温度", info.batterySkinTempC.map { "\($0) ℃（表皮，上次记录）" })
                    row("临界水平", info.atCriticalLevel.map { $0 ? "是" : "否" })
                }
            }
        }
    }

    private func chargingText(_ info: DeviceInfoModel) -> String? {
        guard let charging = info.batteryIsCharging else { return nil }
        if charging {
            return (info.batteryIsFullyCharged ?? false) ? "已充满" : "充电中"
        }
        return "未充电"
    }

    /// v0.3.285：生产与验机（移植爱思「验机报告」——生产状态/FDR 密封/内部版本）
    @ViewBuilder
    private func productionSection(_ info: DeviceInfoModel) -> some View {
        if info.effectiveProductionStatusAp != nil || info.certificateProductionStatus != nil
            || info.fdrSealingStatus != nil || info.configNumber != nil {
            sectionCard(title: "生产与验机", icon: "checkmark.seal") {
                VStack(alignment: .leading, spacing: 0) {
                    row("生产状态(AP)", info.effectiveProductionStatusAp)
                    row("生产状态(SEP)", info.effectiveProductionStatusSep)
                    row("证书生产状态", statusText(info.certificateProductionStatus))
                    row("FDR 密封", statusText(info.fdrSealingStatus))
                    row("内部版本", info.internalBuild.map { $0 ? "是" : "否" })
                    row("配置号", info.configNumber)
                    row("基带版本", info.basebandVersion)
                    row("基带状态", statusText(info.basebandStatus))
                    row("基带芯片", info.basebandChipId)
                }
            }
        }
    }

    private func statusText(_ v: String?) -> String? {
        guard let v, !v.isEmpty else { return nil }
        switch v {
        case "0": return "0（正常）"
        case "1": return "1（异常）"
        default: return v
        }
    }

    /// v0.3.305：零部件序列号（行序对齐爱思第五组）
    ///
    /// 爱思行序：距离传感器/环境光/点阵 → 红外摄像头/电池序列号/震动器编码 → 盖板码 → 屏幕序列号
    ///
    /// 其中**环境光 / 盖板码 / 屏幕序列号 / 电池序列号**已从实测通道读到
    /// （IODeviceTree `product` 节点 + `AppleSmartBattery` 节点）；
    /// **点阵 / 红外摄像头 / 震动器编码 / 距离传感器**在设备侧读不到——
    /// 设备树的 `sacm-jasper` / `pearl-sep` / `haptics` / `prox` 节点都只有寄存器属性、
    /// 没有序列号（爱思能显示是因为它按序列号去自己的服务端取出厂数据，不是从设备读）。
    @ViewBuilder
    private func partsSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "零部件序列号", icon: "cpu") {
            row("距离传感器", Self.notProvided)
            sensitiveRow("环境光", info.ambientLightSerial)
            row("点阵", Self.notProvided)
            row("红外摄像头", Self.notProvided)
            sensitiveRow("电池序列号", info.batterySerial)
            row("震动器编码", Self.notProvided)
            sensitiveRow("盖板码", info.coverglassSerial)
            sensitiveRow("屏幕序列号", info.panelSerial)
        }
    }

    /// 未提供项的说明卡（把「系统未提供」的原因讲清楚，避免看起来像没做）
    private var unavailableNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("关于「\(Self.notProvided)」").font(.footnote.weight(.semibold))
            }
            Text("以下各项在 iOS 27 侧载环境下没有读取通道（不是没做）：\n"
                 + "· 生产日期：需 DateOfFirstUse（iOS 27 已移除该键）或按序列号推算"
                 + "（本机为随机序列号、含字母，爱思自己的算法也推算不出，其设备详情同样显示「未知」）。\n"
                 + "· 点阵 / 红外摄像头 / 震动器编码 / 距离传感器：设备树对应节点没有序列号属性，"
                 + "爱思是拿序列号去它自己的服务端换出厂数据。\n"
                 + "· Wi-Fi 模块 / 无线技术类型 / 协处理器：系统不向侧载 App 暴露（爱思走 PC 端私有通道）。\n"
                 + "· 电池温度 / 警告水平见「电池健康」页——同样只取本机真实存在的键，不填假数据。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    /// 「系统未提供」统一文案
    static let notProvided = "系统未提供"

    /// v0.3.285：功能支持（DeviceSupports* 全集，移植爱思「功能支持」）
    @ViewBuilder
    private func featuresSection(_ info: DeviceInfoModel) -> some View {
        if !info.supportedFeatures.isEmpty {
            sectionCard(title: "功能支持（\(info.supportedFeatures.count) 项）", icon: "sparkles") {
                Text(info.supportedFeatures.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// v0.3.294：设备原始数据——**默认折叠**（此前是平铺在页面最底部的原始键值列表，
    /// 观感像「一堆原始数据」；爱思也是收在「设备原始数据」按钮后面）。
    @ViewBuilder
    private func allValuesSection(_ info: DeviceInfoModel) -> some View {
        if !info.allValues.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(info.allValues.enumerated()), id: \.offset) { _, pair in
                            HStack(alignment: .top, spacing: 12) {
                                Text(pair.0)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(pair.1)
                                    .font(.caption.monospaced())
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle").foregroundStyle(.blue)
                        Text("设备原始数据（\(info.allValues.count) 项）").font(.headline)
                    }
                }
                .tint(.primary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground)))
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, icon: String,
                                            @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.blue)
                Text(title).font(.headline)
            }
            .padding(.bottom, 8)
            body()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value ?? "—")
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }

    /// v0.3.208：敏感行 = 小眼睛 + 复制按钮 + 长按复制
    private func sensitiveRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            HStack(spacing: 6) {
                Text(masked(value))
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let v = value, !v.isEmpty {
                    Button {
                        copyToPasteboard(v)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制 \(label)")
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.4) {
            if let v = value, !v.isEmpty { copyToPasteboard(v) }
        }
    }

    private func masked(_ value: String?) -> String {
        guard let v = value, !v.isEmpty else { return "—" }
        if showSensitive { return v }
        return String(repeating: "•", count: min(v.count, 14))
    }

    private func copyToPasteboard(_ s: String) {
        UIPasteboard.general.string = s
    }

    private func formatBytes(_ b: Int64) -> String {
        let mb = Double(b) / 1024 / 1024
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", mb)
    }

    private var errorCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "info.circle").font(.title).foregroundStyle(.secondary)
            Text("无法读取").font(.headline)
            Text(errorText ?? "未知错误").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await load() } }
                .buttonStyle(.borderedProminent).tint(.blue)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    private func rawCard(_ info: DeviceInfoModel) -> some View {
        let keys = Array(info.raw.keys).sorted().prefix(20)
        return VStack(alignment: .leading, spacing: 6) {
            Text("原始字段").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(keys), id: \.self) { key in
                HStack {
                    Text(key).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(describing: info.raw[key] ?? "").prefix(40))
                        .font(.caption2.monospaced()).lineLimit(1)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}