import SwiftUI

/// v0.3.293：硬盘详情面板（移植爱思「硬盘详情」）
/// 数据源：diagnostics_relay IORegistry → AppleEmbeddedNVMeController（真机实测 46 键）
struct StorageDetailView: View {
    @State private var info: StorageDetailInfo?
    @State private var errorText: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if loading {
                    ProgressView("正在读取硬盘详情…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if let info {
                    overviewCard(info)
                    ioCard(info)
                    geometryCard(info)
                } else {
                    errorCard
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("硬盘详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            info = try await Task.detached(priority: .userInitiated) {
                try StorageDetailService.fetch()
            }.value
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: 基本信息（两列，对齐爱思左侧 8 项）
    private func overviewCard(_ info: StorageDetailInfo) -> some View {
        sectionCard(title: "硬盘信息", icon: "internaldrive.fill") {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    infoRow("供应商", info.flashVendor)
                    infoRow("硬盘类型", info.cellType)
                    infoRow("硬盘型号", info.modelNumber)
                    infoRow("芯片型号", info.chipID)
                    infoRow("固件版本", info.firmwareVersion)
                    infoRow("序列号", info.serialNumber)
                    infoRow("Nand 闪存名", info.marketingName)
                    infoRow("MSP 版本", info.mspVersion)
                }
                VStack(spacing: 0) {
                    infoRow("最大读取字节数", info.maxSegmentByteCountRead.map { String($0) })
                    infoRow("最大写入字节数", info.maxSegmentByteCountWrite.map { String($0) })
                    infoRow("最大读取数", info.maxSegmentCountRead.map { String($0) })
                    infoRow("最大写入数", info.maxSegmentCountWrite.map { String($0) })
                    infoRow("最大写入交换量", info.maxSwapWrite.map { String($0) })
                    infoRow("最小段对齐字节数", info.minSegmentAlignmentByteCount.map { String($0) })
                    infoRow("最小饱和字节数", info.minSaturationByteCount.map { String($0) })
                    infoRow("首选 IO 大小", info.preferredIOSize.map { String($0) })
                }
            }
        }
    }

    // MARK: 其他信息
    private func ioCard(_ info: StorageDetailInfo) -> some View {
        sectionCard(title: "存储与状态", icon: "speedometer") {
            infoRow("容量", info.capacityBytes.map { formatBytes($0) })
            infoRow("硬盘厂商", info.deviceVendor)
            infoRow("加密类型", info.encryptionType)
            infoRow("NAND 状态", info.nandStatus)
            infoRow("NVMe 版本", info.nvmeRevision)
            infoRow("物理接口", info.interconnect)
            infoRow("单次最大读", info.maxByteCountRead.map { formatBytes(Int64($0)) })
            infoRow("单次最大写", info.maxByteCountWrite.map { formatBytes(Int64($0)) })
            if let frag = info.fragmentation {
                infoRow("碎片率", "\(frag)")
            }
        }
    }

    // MARK: 颗粒结构
    private func geometryCard(_ info: StorageDetailInfo) -> some View {
        sectionCard(title: "颗粒结构", icon: "square.grid.3x3") {
            infoRow("页大小", info.pageSize.map { formatBytes(Int64($0)) })
            infoRow("每块页数（MLC）", info.pagesPerBlockMLC.map { String($0) })
            infoRow("每块页数（SLC）", info.pagesPerBlockSLC.map { String($0) })
            infoRow("总线数", info.numBus.map { String($0) })
            if !info.diesPerBus.isEmpty {
                infoRow("每总线 Die 数", info.diesPerBus.map { String($0) }.joined(separator: " / "))
            }
            infoRow("每 Die 的 CAU", info.cauPerDie.map { String($0) })
            infoRow("每 CAU 块数", info.blocksPerCau.map { String($0) })
            infoRow("DIP 数", info.numDip.map { String($0) })
        }
    }

    private func errorCard() -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "internaldrive", tint: .secondary, symbolSize: 20, frameSize: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("无法读取硬盘详情").font(.subheadline.weight(.semibold))
                    if let err = errorText, !PairingGate.isPairingError(err) {
                        Text(err).font(.caption).foregroundStyle(Color.secondary).lineLimit(3)
                    }
                }
                Spacer()
            }
            Button {
                Task { await load() }
            } label: {
                Text("重试").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
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

    private func infoRow(_ label: String, _ value: String?) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(value ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 7)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return "\(bytes) B" }
        return String(format: "%.2f %@", value, units[idx])
    }
}
