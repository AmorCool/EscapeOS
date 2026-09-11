import SwiftUI

/// 设备瘦身（爱思助手 8.0「设备瘦身」移植）—— 主页新板块.
///
/// 结构对齐爱思：设备头 + 空间占用环形图与图例 + 备份警告 + 扫描结果分组
/// （系统缓存文件 / 用户日志 / 其他临时文件 / 较大应用）+ 已选统计 + 开始瘦身.
///
/// 实现要点：行/分组全部走纯数据（`DeviceSlimService.Group` / `Item`），
/// 视图只负责渲染——避免把大量 `@ViewBuilder` 分组堆进一个 body
/// （v0.3.307 设备信息页闪退的根因就是 body 类型过深）.
struct DeviceSlimView: View {

    private enum Phase: Equatable {
        case loading      // 读空间占用
        case scanning     // 扫描可清理项
        case ready        // 结果就绪（可勾选）
        case cleaning     // 清理中
        case finished     // 已瘦身
    }

    private struct SectionSpec: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
    }

    @State private var phase: Phase = .loading
    @State private var usage: DeviceSlimService.SpaceUsage?
    @State private var groups: [DeviceSlimService.Group] = []
    @State private var selection: Set<String> = []
    @State private var statusText = "正在分析您的设备空间占用情况…"
    @State private var confirmClean = false
    @State private var resultText: String?
    @State private var errorText: String?

    // MARK: - 派生数据

    /// 可勾选的项（较大应用不参与）
    private var selectableItems: [DeviceSlimService.Item] {
        groups.filter { $0.kind.selectable }.flatMap(\.items)
    }

    private var selectedItems: [DeviceSlimService.Item] {
        selectableItems.filter { selection.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    private var isBusy: Bool { phase == .loading || phase == .scanning || phase == .cleaning }

    /// 环形图分段（累加比例）—— 用结构体而非元组：
    /// Swift 的 KeyPath 不支持元组成员，`ForEach(_, id: \.id)` 会编译失败.
    /// 必须是 fileprivate（同文件的 `DeviceSlimDonut` 要引用它）.
    fileprivate struct ChartSegment: Identifiable {
        let id: String
        let start: Double
        let end: Double
        let colorHex: UInt32
    }

    private var chartSegments: [ChartSegment] {
        guard let usage, usage.total > 0 else { return [] }
        let sum = usage.slices.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        guard sum > 0 else { return [] }
        var accumulated = 0.0
        var out: [ChartSegment] = []
        for slice in usage.slices {
            let fraction = Double(max(0, slice.bytes)) / Double(sum)
            out.append(ChartSegment(id: slice.id, start: accumulated,
                                    end: accumulated + fraction, colorHex: slice.colorHex))
            accumulated += fraction
        }
        return out
    }

    // MARK: - Body

    var body: some View {
        List {
            overviewSection
            warningBanner
            actionSection
            ForEach(groups) { group in
                groupSection(group)
            }
            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设备瘦身")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定开始瘦身？",
                            isPresented: $confirmClean,
                            titleVisibility: .visible) {
            Button("删除选中的 \(selectedItems.count) 项", role: .destructive) { startClean() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除这些缓存与临时文件（预计释放 \(DeviceSlimService.formatBytes(selectedBytes))）。照片、聊天记录等用户数据不在清理范围内。")
        }
        .task { await bootstrap() }
    }

    // MARK: - 1. 设备 + 空间占用

    private var overviewSection: some View {
        Section {
            if let usage {
                HStack(spacing: 14) {
                    Image(systemName: "iphone.gen3")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usage.deviceName).font(.headline)
                        Text(usage.capacityText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)

                VStack(spacing: 10) {
                    DeviceSlimDonut(segments: chartSegments)
                        .frame(width: 168, height: 168)
                    Text("已用 \(DeviceSlimService.formatBytes(usage.used)) / 总量 \(DeviceSlimService.formatBytes(usage.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)

                ForEach(usage.slices) { slice in
                    legendRow(slice)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取空间占用…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("空间占用情况")
        }
    }

    private func legendRow(_ slice: DeviceSlimService.UsageSlice) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(slimHex: slice.colorHex))
                .frame(width: 9, height: 9)
            Text(slice.label).font(.subheadline)
            Spacer(minLength: 0)
            Text(DeviceSlimService.formatBytes(slice.bytes))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - 2. 警告

    private var warningBanner: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                Text("瘦身前请备份好重要数据，谨防数据丢失")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 3. 状态与操作

    private var actionSection: some View {
        Section {
            if isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(statusText).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("已选 \(selectedItems.count) 项")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("可释放 \(DeviceSlimService.formatBytes(selectedBytes)) 空间")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(selectedBytes > 0 ? .red : .secondary)
                        .monospacedDigit()
                }

                Button {
                    confirmClean = true
                } label: {
                    Text(phase == .finished ? "再次瘦身" : "开始瘦身")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedItems.isEmpty ? Color.gray.opacity(0.35) : Color.blue)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(selectedItems.isEmpty)

                Button {
                    Task { await runScan() }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
            }

            if let resultText {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(resultText).font(.footnote)
                    Spacer(minLength: 0)
                }
            }
        } footer: {
            Text(scanFooter)
                .font(.caption2)
        }
    }

    private var scanFooter: String {
        switch phase {
        case .loading, .scanning:
            return "正在扫描设备…"
        case .ready, .finished:
            let count = selectableItems.count
            return count == 0
                ? "本机可达范围内没有需要清理的缓存（免越狱只清理媒体分区内可再生的缓存）。"
                : "共 \(count) 项可清理；「较大应用」只作提示，清理需卸载重装，会丢失文稿与数据。"
        case .cleaning:
            return "正在删除，请勿断开设备…"
        }
    }

    // MARK: - 4. 分组

    private func groupSection(_ group: DeviceSlimService.Group) -> some View {
        Section {
            if group.items.isEmpty {
                Text("未发现可清理项")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(group.items) { item in
                itemRow(item)
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: group.kind.icon)
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(group.kind.rawValue)
                Spacer(minLength: 0)
                if !group.items.isEmpty {
                    Text("\(group.items.count) 项 \(DeviceSlimService.formatBytes(group.totalBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } footer: {
            if !group.items.isEmpty, group.kind.selectable {
                Text(group.kind == .bigApps
                     ? "通过批量重装应用，清理应用的冗余文稿和数据。"
                     : group.kind.subtitle)
                    .font(.caption2)
            }
        }
    }

    private func itemRow(_ item: DeviceSlimService.Item) -> some View {
        Button {
            guard item.deletable else { return }
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection.contains(item.id) && item.deletable
                      ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(item.deletable ? (selection.contains(item.id) ? .blue : .secondary) : Color.gray.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(DeviceSlimService.formatBytes(item.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!item.deletable)
    }

    // MARK: - 流程

    private func bootstrap() async {
        await loadUsage()
        await runScan()
    }

    private func loadUsage() async {
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                try DeviceSlimService.loadUsage()
            }.value
            usage = value
        } catch {
            errorText = "读取空间占用失败：\(error.localizedDescription)"
        }
    }

    private func runScan() async {
        phase = .scanning
        statusText = "正在扫描…"
        errorText = nil
        resultText = nil
        do {
            let scanned = try await Task.detached(priority: .userInitiated) {
                try DeviceSlimService.scan { message in
                    Task { @MainActor in statusText = message }
                }
            }.value
            groups = scanned
            selection = Set(scanned.filter { $0.kind.selectable }.flatMap(\.items).map(\.id))
            phase = .ready
        } catch {
            phase = .ready
            errorText = "扫描失败：\(error.localizedDescription)"
        }
    }

    private func startClean() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        phase = .cleaning
        statusText = "正在删除…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DeviceSlimService.clean(items: targets) { index, total in
                        Task { @MainActor in statusText = "正在删除 \(index)/\(total)…" }
                    }
                }.value
                resultText = "本次共释放空间 \(DeviceSlimService.formatBytes(result.freed))"
                    + (result.failures.isEmpty ? "" : "（\(result.failures.count) 项失败）")
                errorText = result.failures.isEmpty ? nil : result.failures.prefix(3).joined(separator: "\n")
                phase = .finished
                await loadUsage()
                await runScan()
            } catch {
                phase = .ready
                errorText = "瘦身失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 环形图

/// 空间占用环形图（按比例分段；与爱思圆环一致）
private struct DeviceSlimDonut: View {
    let segments: [DeviceSlimView.ChartSegment]

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 24)
            ForEach(segments) { segment in
                DonutArc(start: segment.start, end: segment.end)
                    .stroke(Color(slimHex: segment.colorHex),
                            style: StrokeStyle(lineWidth: 24, lineCap: .butt))
            }
        }
    }
}

private struct DonutArc: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard end > start else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(center: center,
                    radius: radius,
                    startAngle: .degrees(start * 360 - 90),
                    endAngle: .degrees(end * 360 - 90),
                    clockwise: false)
        return path
    }
}

private extension Color {
    /// 0xRRGGBB → Color
    init(slimHex hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
