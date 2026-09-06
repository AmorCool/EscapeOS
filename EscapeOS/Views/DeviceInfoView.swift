import SwiftUI

/// v0.3.207：设备信息面板 —— 参考 iDescriptor 信息面板。
/// 本机信息（机型/系统/CPU/内存/存储）即时显示；序列号/设备名需配对后从 lockdown 拿。
struct DeviceInfoView: View {
    @State private var info = DeviceInfoService.collectLocal()
    @State private var loadingLockdown = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                deviceHero
                specGrid
                if loadingLockdown {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取设备身份…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    Button {
                        Task { await enrich() }
                    } label: {
                        Label(info.serialNumber == nil ? "读取设备序列号" : "刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }
                Text("「设备信息」数据来自本机 sysctl；序列号/设备名通过 LocalDevVPN 配对读取。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("设备信息")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func enrich() async {
        loadingLockdown = true
        defer { loadingLockdown = false }
        let base = DeviceInfoService.collectLocal()
        let enriched = await Task.detached(priority: .userInitiated) {
            DeviceInfoService.enrichWithLockdown(base)
        }.value
        info = enriched
    }

    private var deviceHero: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 46))
                .foregroundStyle(.blue)
            Text(info.deviceName ?? info.modelName)
                .font(.title3.weight(.semibold))
            Text("\(info.productType) · iOS \(info.systemVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }

    private var specGrid: some View {
        let rows: [(String, String)] = [
            ("机型", info.modelName),
            ("型号标识", info.productType),
            ("系统版本", "iOS \(info.systemVersion)"),
            ("设备名称", info.deviceName ?? "—"),
            ("序列号", info.serialNumber ?? "未配对"),
            ("CPU 核心", "\(info.cpuCount) 核"),
            ("内存", "\(info.memoryMB) MB"),
            ("存储", "\(info.storageFreeGB) GB 可用 / \(info.storageTotalGB) GB"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(rows, id: \.0) { row in
                VStack(spacing: 4) {
                    Text(row.1)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .minimumScaleFactor(0.65)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                    Text(row.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground)))
            }
        }
    }
}