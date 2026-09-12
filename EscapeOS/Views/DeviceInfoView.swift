import SwiftUI
import UIKit

/// v0.3.208：设备信息面板 —— 字段清单对齐爱思「设备详情」.
///
/// v0.3.307：**改成数据驱动**。所有行/分组由 `sections(_:)` 组装成
/// `[DeviceInfoSectionSpec]`，渲染交给 `DeviceInfoSectionCard` 等独立小视图。
/// 原因见 `DeviceInfoSections.swift` 顶部注释：原先单 body 堆 11 个分组 + Group，
/// 编译出的嵌套泛型类型过深，Swift 运行时解析该类型时栈溢出（真机崩溃
/// LiveProcess-2026-09-11-163343.ips，主线程 swizzling 在 `decodeMangledType` 递归里）。
struct DeviceInfoView: View {
    @State private var info: DeviceInfoModel?
    @State private var errorText: String?
    @State private var loading = true
    /// 隐私敏感字段统一小眼睛状态（默认全部隐藏）
    @State private var showSensitive = false
    /// 内置浏览器（保修期限等外链查询，不静默跳外部 App）
    @State private var browserTarget: LinkShareTarget?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if loading {
                    ProgressView("正在读取设备信息…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if let info {
                    hero(info)
                    ForEach(sections(info)) { section in
                        DeviceInfoSectionCard(section: section,
                                              showSensitive: showSensitive,
                                              onCopy: copy,
                                              onOpenLink: openLink)
                    }
                    StorageDetailLinkCard()
                    if !info.supportedFeatures.isEmpty {
                        DeviceInfoTextCard(title: "功能支持（\(info.supportedFeatures.count) 项）",
                                           icon: "sparkles",
                                           text: info.supportedFeatures.joined(separator: " · "))
                    }
                    if !info.allValues.isEmpty {
                        DeviceInfoRawCard(values: info.allValues)
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
        .sheet(item: $browserTarget) { target in
            InAppBrowserView(title: target.title, url: target.url)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if info != nil {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showSensitive.toggle() } label: {
                    // v0.3.221：图标=当前状态（显示中=睁眼，隐藏中=闭眼）
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

    private func copy(_ s: String) {
        UIPasteboard.general.string = s
    }

    /// 保修期限只能联网查（Apple 要过验证码，爱思自己也有 Capcha 任务）——
    /// 这里给官方查询页并在内置浏览器打开，序列号带上省得手输。
    private func warrantyURL(_ info: DeviceInfoModel) -> String {
        guard let sn = info.serialNumber, !sn.isEmpty else {
            return "https://checkcoverage.apple.com/cn/zh/"
        }
        return "https://checkcoverage.apple.com/cn/zh/?sn=\(sn)"
    }

    private func openLink(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        browserTarget = LinkShareTarget(title: "Apple 保修查询", url: url)
    }

    // MARK: - 顶部

    private func hero(_ info: DeviceInfoModel) -> some View {
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

    // MARK: - 数据组装（行序对齐爱思「设备详情」）

    private func sections(_ info: DeviceInfoModel) -> [DeviceInfoSectionSpec] {
        [deviceSection(info),
         systemSection(info),
         networkSection(info),
         hardwareSection(info),
         batterySection(info),
         partsSection(info),
         storageSection(info)]
    }

    private func deviceSection(_ info: DeviceInfoModel) -> DeviceInfoSectionSpec {
        DeviceInfoSectionSpec(title: "设备", icon: "iphone.gen3", rows: [
            .init(id: 1, label: "设备名称", value: info.deviceName, sensitive: false),
            .init(id: 2, label: "容量颜色", value: capacityColorText(info), sensitive: false),
            .init(id: 3, label: "上市日期", value: info.releaseDate, sensitive: false),
            .init(id: 4, label: "设备型号", value: info.modelName, sensitive: false),
            .init(id: 5, label: "激活状态", value: activationText(info.activationState), sensitive: false),
            .init(id: 6, label: "生产日期", value: productionDateText, sensitive: false),
            .init(id: 7, label: "序列号", value: info.serialNumber, sensitive: true),
            .init(id: 8, label: "越狱状态", value: info.jailbroken.map { $0 ? "已越狱" : "未越狱" }, sensitive: false),
            // v0.3.322：对齐爱思首屏的四项检测
            .init(id: 20, label: "激活锁（ID锁）",
                  value: info.activationLockEnabled.map { $0 ? "已开启" : "未开启" },
                  sensitive: false),
            .init(id: 21, label: "iCloud",
                  value: info.iCloudSignedIn.map { $0 ? "已开启" : "未开启" },
                  sensitive: false),
            .init(id: 22, label: "崩溃日志",
                  value: info.crashLogCount.map { "\($0) 次" },
                  sensitive: false),
            .init(id: 23, label: "保修期限",
                  value: nil,
                  sensitive: false,
                  link: warrantyURL(info)),
            .init(id: 9, label: "销售类型", value: info.salesType, sensitive: false),
            .init(id: 10, label: "主板序列号", value: info.mlbSerial, sensitive: true),
            .init(id: 11, label: "产品类型", value: productTypeText(info), sensitive: false),
            .init(id: 12, label: "销售型号", value: [info.modelNumber, info.region].compactMap { $0 }.joined(separator: " "), sensitive: false),
            .init(id: 13, label: "ECID", value: info.ecid, sensitive: true),
            .init(id: 14, label: "固件版本", value: versionText(info), sensitive: false),
            // 销售地区 = RegionInfo（渠道/国家，如 LL/A → 美国）
            .init(id: 15, label: "销售地区", value: [info.region, info.regionName].compactMap { $0 }.joined(separator: " "), sensitive: false),
            .init(id: 16, label: "UDID", value: info.udid, sensitive: true),
            .init(id: 17, label: "硬件型号", value: info.uniqueModel, sensitive: false),
            .init(id: 18, label: "设备类别", value: info.deviceClass, sensitive: false),
        ])
    }

    private func systemSection(_ info: DeviceInfoModel) -> DeviceInfoSectionSpec {
        DeviceInfoSectionSpec(title: "系统与时区", icon: "gearshape.2.fill", rows: [
            .init(id: 1, label: "时区", value: info.timeZone, sensitive: false),
            // 地区 = 本机语言+区域设置（如 zh-Hans_JP），与「销售地区」是两项独立检测
            .init(id: 2, label: "地区", value: info.localeRegion, sensitive: false),
            .init(id: 3, label: "24 小时制", value: info.uses24HourClock.map { $0 ? "是" : "否" }, sensitive: false),
            .init(id: 4, label: "充电次数", value: info.cycleCount.map { "\($0) 次" }, sensitive: false),
            .init(id: 5, label: "剩余电量", value: info.batteryLevel.map { "\($0)%" }, sensitive: false),
            .init(id: 6, label: "电池寿命", value: info.batteryHealthPercent.map { "\($0)%" }, sensitive: false),
            .init(id: 7, label: "iBoot 固件", value: info.firmwareVersion, sensitive: false),
        ])
    }

    private func networkSection(_ info: DeviceInfoModel) -> DeviceInfoSectionSpec {
        DeviceInfoSectionSpec(title: "卡槽与网络", icon: "antenna.radiowaves.left.and.right", rows: [
            .init(id: 1, label: "卡槽类型", value: simSlotKind(info), sensitive: false),
            .init(id: 2, label: "IMEI 1", value: info.imei, sensitive: true),
            .init(id: 3, label: "eSIM 卡1 信息", value: info.carrier1, sensitive: false),
            .init(id: 4, label: "有无卡托", value: info.simTrayInserted.map { $0 ? "有" : "无" }, sensitive: false),
            .init(id: 5, label: "IMEI 2", value: info.imei2, sensitive: true),
            .init(id: 6, label: "eSIM 卡2 信息", value: info.carrier2, sensitive: false),
            .init(id: 7, label: "基带版本", value: info.basebandVersion, sensitive: false),
            .init(id: 8, label: "Wi-Fi 地址", value: info.wiFiAddress, sensitive: false),
            .init(id: 9, label: "SIM 卡状态", value: info.simStatus, sensitive: false),
            .init(id: 10, label: "基带激活版本", value: info.basebandActivationTicket, sensitive: false),
            .init(id: 11, label: "蓝牙地址", value: info.bluetoothAddress, sensitive: false),
            .init(id: 12, label: "SIM 卡托状态", value: info.simTrayStatus, sensitive: false),
            .init(id: 13, label: "基带状态", value: info.basebandStatus, sensitive: false),
            .init(id: 14, label: "蜂窝地址", value: info.ethernetAddress, sensitive: false),
            .init(id: 15, label: "通话功能", value: info.callCapable.map { $0 ? "是" : "否" }, sensitive: false),
            .init(id: 16, label: "基带序列号", value: info.basebandSerial, sensitive: true),
            .init(id: 17, label: "IMSI", value: info.imsi, sensitive: true),
            .init(id: 18, label: "协议版本", value: info.protocolVersion, sensitive: false),
            .init(id: 19, label: "基带芯片", value: info.basebandChipset, sensitive: false),
            .init(id: 20, label: "Wi-Fi 序列号", value: info.wirelessBoardSerial, sensitive: false),
            .init(id: 21, label: "ICCID", value: info.iccid, sensitive: true),
            .init(id: 22, label: "IMSI 2", value: info.imsi2, sensitive: true),
        ])
    }

    private func hardwareSection(_ info: DeviceInfoModel) -> DeviceInfoSectionSpec {
        DeviceInfoSectionSpec(title: "CPU 与硬件", icon: "cpu", rows: [
            .init(id: 1, label: "CPU 类型", value: info.cpuName, sensitive: false),
            .init(id: 2, label: "屏幕大小", value: info.screenInches.map { "\($0) 英寸" }, sensitive: false),
            .init(id: 3, label: "CPU 核心", value: "\(info.cpuCount) 核", sensitive: false),
            .init(id: 4, label: "屏幕分辨率", value: screenResolution, sensitive: false),
            .init(id: 5, label: "CPU 频率", value: info.cpuFrequency, sensitive: false),
            .init(id: 6, label: "硬盘类型", value: info.diskCellType, sensitive: false),
            .init(id: 7, label: "硬件版本", value: info.hardwareVersion, sensitive: false),
            .init(id: 8, label: "分区类型", value: info.partitionType, sensitive: false),
            .init(id: 9, label: "硬件平台", value: info.hardwarePlatform, sensitive: false),
            .init(id: 10, label: "Wi-Fi 芯片", value: info.wifiChipset, sensitive: false),
            .init(id: 11, label: "物理内存", value: "\(info.memoryMB) MB", sensitive: false),
            .init(id: 12, label: "CPU 架构", value: info.cpuArchitecture, sensitive: false),
        ])
    }

    private func batterySection(_ info: DeviceInfoModel) -> DeviceInfoSectionSpec {
        DeviceInfoSectionSpec(title: "电池", icon: "battery.100", rows: [
            .init(id: 1, label: "电池健康度", value: info.batteryHealthPercent.map { "\($0)%" }, sensitive: false),
            .init(id: 2, label: "循环次数", value: info.cycleCount.map { "\($0) 次" }, sensitive: false),
            .init(id: 3, label: "设计容量", value: info.designCapacity.map { "\($0) mAh" }, sensitive: false),
            .init(id: 4, label: "实际容量", value: info.maxCapacity.map { "\($0) mAh" }, sensitive: false),
            .init(id: 5, label: "当前电量", value: info.batteryLevel.map { "\($0)%" }, sensitive: false),
            .init(id: 6, label: "充电状态", value: chargingText(info), sensitive: false),
            .init(id: 7, label: "电池型号", value: info.batteryModelID, sensitive: false),
            .init(id: 8, label: "电池电压", value: info.batteryVoltageMV.map { String(format: "%.2f V", Double($0) / 1000.0) }, sensitive: false),
            .init(id: 9, label: "电池电流", value: info.batteryAmperageMA.map { "\($0) mA" }, sensitive: false),
            .init(id: 10, label: "临界水平", value: info.atCriticalLevel.map { $0 ? "是" : "否" }, sensitive: false),
            .init(id: 11, label: "电池序列号", value: info.batterySerial, sensitive: true),
        ])
    }

    private func partsSection(_ info: DeviceInfoModel) -> DeviceInfoSectionSpec {
        DeviceInfoSectionSpec(title: "零部件序列号", icon: "wrench.and.screwdriver", rows: [
            .init(id: 1, label: "环境光", value: info.ambientLightSerial, sensitive: true),
            .init(id: 2, label: "电池序列号", value: info.batterySerial, sensitive: true),
            .init(id: 3, label: "盖板码", value: info.coverglassSerial, sensitive: true),
            .init(id: 4, label: "屏幕序列号", value: info.panelSerial, sensitive: true),
        ])
    }

    private func storageSection(_ info: DeviceInfoModel) -> DeviceInfoSectionSpec {
        DeviceInfoSectionSpec(title: "存储", icon: "internaldrive", rows: [
            .init(id: 1, label: "总容量", value: info.totalDiskBytes.map { formatBytes($0) }, sensitive: false),
            .init(id: 2, label: "数据容量", value: info.totalDataBytes.map { formatBytes($0) }, sensitive: false),
            .init(id: 3, label: "系统占用", value: info.totalSystemBytes.map { formatBytes($0) }, sensitive: false),
            .init(id: 4, label: "本机可用 / 总", value: "\(info.storageFreeGB) GB / \(info.storageTotalGB) GB", sensitive: false),
        ])
    }

    // MARK: - 取值辅助

    /// 容量 + 机身颜色（爱思显示「512GB 黑色」）。颜色名只在有实证映射时才翻译。
    private func capacityColorText(_ info: DeviceInfoModel) -> String? {
        guard info.storageTotalGB > 0 else { return nil }
        let cap = "\(info.storageTotalGB)GB"
        if let name = DeviceCatalog.deviceColorName(info.deviceColor) { return "\(cap) \(name)" }
        if let code = info.deviceColor, !code.isEmpty { return "\(cap)（颜色代码 \(code)）" }
        return cap
    }

    /// 爱思也取不到本机项（随机序列号推算失败 / 系统已移除该键）时统一显示「未知」
    private var productionDateText: String { "未知" }

    /// 「固件版本」= iOS 版本 (构建号) —— 爱思把 iOS 版本这一行叫「固件版本」
    private func versionText(_ info: DeviceInfoModel) -> String? {
        guard let build = info.buildVersion, !build.isEmpty else { return info.systemVersion }
        return "\(info.systemVersion) (\(build))"
    }

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

    private func chargingText(_ info: DeviceInfoModel) -> String? {
        guard let charging = info.batteryIsCharging else { return nil }
        if charging { return (info.batteryIsFullyCharged ?? false) ? "已充满" : "充电中" }
        return "未充电"
    }

    /// 卡槽类型：由「SIM1/SIM2 是否 eSIM」推导（两张都内嵌 = 无实体卡槽）.
    /// 本机实测（iPhone15,4，SIM1IsEmbedded/SIM2IsEmbedded 均为 true）与爱思「单卡」一致.
    private func simSlotKind(_ info: DeviceInfoModel) -> String? {
        guard let embedded = info.simsAreEmbedded else { return nil }
        return embedded ? "单卡" : "双卡"
    }

    private var screenResolution: String? {
        let b = UIScreen.main.nativeBounds
        guard b.width > 0, b.height > 0 else { return nil }
        return "\(Int(max(b.width, b.height))) x \(Int(min(b.width, b.height)))"
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
}
