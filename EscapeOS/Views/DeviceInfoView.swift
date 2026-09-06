import SwiftUI
import UIKit

/// v0.3.208：设备信息面板 —— iDescriptor 完整字段（基础/硬件/序列号/网络/存储）。
/// 序列号/UDID/IMEI/ECID/MLB 等敏感字段：统一小眼睛显示/隐藏 + 长按复制。
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
                    deviceHero(info)
                    basicSection(info)
                    identifiersSection(info)
                    networkSection(info)
                    storageSection(info)
                    if info.raw.count > 0 { rawCard(info) }
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
                    Image(systemName: showSensitive ? "eye.slash" : "eye")
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

    private func basicSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "设备", icon: "iphone.gen3") {
            row("设备名称", info.deviceName)
            row("型号标识", info.productType)
            row("机型", info.modelName)
            row("型号编号", info.modelNumber)
            row("设备类别", info.deviceClass)
            row("硬件型号", info.hardwareModel)
            row("硬件平台", info.hardwarePlatform)
            row("CPU 架构", info.cpuArchitecture)
            row("生产设备", info.productionDevice)
            row("越狱", info.jailbroken.map { $0 ? "是" : "否" })
        }
    }

    @ViewBuilder
    private func identifiersSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "系统与固件", icon: "gearshape.2.fill") {
            row("iOS 版本", "iOS \(info.systemVersion)")
            row("Build 版本", info.buildVersion)
            row("固件版本", info.firmwareVersion)
        }
        sectionCard(title: "激活与地区", icon: "checkmark.shield.fill") {
            row("激活状态", info.activationState)
            row("地区", info.region)
            row("设备颜色", info.deviceColor)
        }
        sectionCard(title: "身份标识（敏感）", icon: "key.fill") {
            sensitiveRow("序列号", info.serialNumber)
            sensitiveRow("UDID", info.udid)
            sensitiveRow("IMEI", info.imei)
            sensitiveRow("MEID", info.meid)
            sensitiveRow("ECID", info.ecid)
            sensitiveRow("MLB 序列号", info.mlbSerial)
            sensitiveRow("基带序列号", info.basebandSerial)
        }
    }

    private func networkSection(_ info: DeviceInfoModel) -> some View {
        sectionCard(title: "网络接口", icon: "wifi") {
            row("Wi-Fi MAC", info.wiFiAddress)
            row("以太网 MAC", info.ethernetAddress)
            row("蓝牙 MAC", info.bluetoothAddress)
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
            row("CPU 核心", "\(info.cpuCount) 核")
            row("物理内存", "\(info.memoryMB) MB")
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