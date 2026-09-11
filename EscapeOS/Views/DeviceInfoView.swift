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
                    // （设备 → 系统与时区 → 卡槽与网络 → CPU 与硬件 → 电池 → 生产验机 → 传感器备件 → 存储）
                    deviceHero(info)
                    basicSection(info)
                    systemSection(info)
                    networkSection(info)
                    hardwareSection(info)
                    batterySection(info)
                    productionSection(info)
                    partsSection(info)
                    storageSection(info)
                    featuresSection(info)
                    allValuesSection(info)
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

    /// v0.3.294：设备（对齐爱思「设备详情」第一组）
    private func basicSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "设备", icon: "iphone.gen3") {
            row("设备名称", info.deviceName)
            row("设备型号", info.modelName)
            row("产品类型", productTypeText(info))
            row("上市日期", info.releaseDate)
            row("销售型号", [info.modelNumber, info.region].compactMap { $0 }.joined(separator: " "))
            row("销售地区", [info.region, info.regionName].compactMap { $0 }.joined(separator: " "))
            row("销售类型", info.salesType)
            sensitiveRow("序列号", info.serialNumber)
            sensitiveRow("主板序列号", info.mlbSerial)
            sensitiveRow("ECID", info.ecid)
            sensitiveRow("UDID", info.udid)
            row("激活状态", activationText(info.activationState))
            row("越狱状态", info.jailbroken.map { $0 ? "已越狱" : "未越狱" })
        }
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

    /// v0.3.294：系统与时区（对齐爱思第二组，含 24 小时制/协议版本/分区/硬件版本）
    @ViewBuilder
    private func systemSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "系统与时区", icon: "gearshape.2.fill") {
            row("系统版本", info.buildVersion.map { "\(info.systemVersion) (\($0))" } ?? info.systemVersion)
            row("固件版本", info.firmwareVersion)
            row("时区", info.timeZone)
            row("地区", info.localeRegion ?? info.region)
            row("24 小时制", info.uses24HourClock.map { $0 ? "是" : "否" })
            row("协议版本", info.protocolVersion)
            row("分区类型", info.partitionType)
            row("硬件版本", info.hardwareVersion)
        }
    }

    /// v0.3.294：CPU 与硬件（对齐爱思第四组）
    @ViewBuilder
    private func hardwareSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "CPU 与硬件", icon: "cpu") {
            row("CPU 类型", info.cpuName)
            row("CPU 核心", "\(info.cpuCount) 核")
            row("CPU 频率", info.cpuFrequency)
            row("物理内存", "\(info.memoryMB) MB")
            row("屏幕大小", info.screenInches.map { "\($0) 英寸" })
            row("屏幕分辨率", screenResolution)
            row("CPU 架构", info.cpuArchitecture)
            row("硬件型号", info.hardwareModel)
            row("硬件平台", info.hardwarePlatform)
        }
    }

    /// 屏幕分辨率（取设备实时值；UIScreen 需主线程）
    private var screenResolution: String? {
        let b = UIScreen.main.nativeBounds
        guard b.width > 0, b.height > 0 else { return nil }
        return "\(Int(max(b.width, b.height))) x \(Int(min(b.width, b.height)))"
    }

    /// v0.3.294：卡槽与网络（对齐爱思第三组）
    @ViewBuilder
    private func networkSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "卡槽与网络", icon: "antenna.radiowaves.left.and.right") {
            sensitiveRow("IMEI 1", info.imei)
            sensitiveRow("IMEI 2", info.imei2)
            row("eSIM 卡1 信息", info.carrier1)
            row("eSIM 卡2 信息", info.carrier2)
            sensitiveRow("IMSI", info.imsi)
            sensitiveRow("IMSI 2", info.imsi2)
            row("SIM 卡状态", info.simStatus)
            row("SIM 卡托状态", info.simTrayStatus)
            row("基带版本", info.basebandVersion)
            row("基带状态", info.basebandStatus)
            sensitiveRow("基带序列号", info.basebandSerial)
            sensitiveRow("MEID", info.meid)
            row("Wi-Fi 地址", info.wiFiAddress)
            row("蓝牙地址", info.bluetoothAddress)
            row("蜂窝地址", info.ethernetAddress)
            row("Wi-Fi 序列号", info.wirelessBoardSerial)
        }
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
    @ViewBuilder
    private func batterySection(_ info: DeviceInfoModel) -> some View {
        if info.batteryHealthPercent != nil || info.cycleCount != nil || info.designCapacity != nil {
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
                    sensitiveRow("电池序列号", info.batterySerial)
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

    /// v0.3.285：零部件序列号（移植爱思「硬件」页，默认打码）
    @ViewBuilder
    private func partsSection(_ info: DeviceInfoModel) -> some View {
        if info.coverglassSerial != nil || info.lunaFlexSerial != nil
            || info.mesaSerial != nil || info.arcModuleSerial != nil {
            sectionCard(title: "零部件序列号", icon: "cpu") {
                VStack(alignment: .leading, spacing: 0) {
                    sensitiveRow("屏幕盖板", info.coverglassSerial)
                    sensitiveRow("Luna 排线", info.lunaFlexSerial)
                    sensitiveRow("Mesa(指纹)", info.mesaSerial)
                    sensitiveRow("Arc 模块", info.arcModuleSerial)
                }
            }
        }
    }

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