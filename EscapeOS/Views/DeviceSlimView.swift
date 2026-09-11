import SwiftUI

/// 设备瘦身（爱思助手 8.0「设备瘦身」移植）—— 主页板块.
///
/// 版式对齐爱思：设备头 + **环形图与图例同一张卡**（v0.3.314 修掉之前的"割裂感"）
/// + 备份警告 + 已选统计 + 分组（系统缓存文件 / 用户日志 / 其他临时文件 / 较大应用）
/// + 「较大应用」按爱思做成**应用名称 / 应用大小 / 文档大小 / 操作**表，勾选 = 重装.
///
/// 视图只做渲染，行与分组全部走纯数据（`DeviceSlimService.Group` / `Item`），
/// 避免把大量 `@ViewBuilder` 分组堆进一个 body（v0.3.307 设备信息页闪退的根因）.
struct DeviceSlimView: View {

    private enum Phase: Equatable {
        case loading, scanning, ready, cleaning, reinstalling, finished
    }

    fileprivate struct ChartSegment: Identifiable {
        let id: String
        let start: Double
        let end: Double
        let colorHex: UInt32
    }

    @State private var phase: Phase = .loading
    @State private var usage: DeviceSlimService.SpaceUsage?
    @State private var groups: [DeviceSlimService.Group] = []
    @State private var selection: Set<String> = []            // 缓存项
    @State private var reinstallSelection: Set<String> = []   // 较大应用（重装）
    @State private var statusText = "正在分析您的设备空间占用情况…"
    @State private var confirmClean = false
    @State private var confirmReinstall = false
    @State private var resultText: String?
    @State private var errorText: String?
    @State private var fromCache = false

    // MARK: - 派生数据

    private var selectableItems: [DeviceSlimService.Item] {
        groups.filter { $0.kind.selectable }.flatMap(\.items)
    }
    private var selectedItems: [DeviceSlimService.Item] {
        selectableItems.filter { selection.contains($0.id) }
    }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    private var bigAppItems: [DeviceSlimService.Item] {
        groups.first { $0.kind == .bigApps }?.items ?? []
    }
    private var reinstallableApps: [DeviceSlimService.Item] {
        bigAppItems.filter { $0.ipaFileName != nil }
    }
    private var reinstallTargets: [DeviceSlimService.Item] {
        bigAppItems.filter { reinstallSelection.contains($0.id) && $0.ipaFileName != nil }
    }
    private var reinstallDocBytes: Int64 {
        reinstallTargets.reduce(0) { $0 + $1.docSize }
    }

    private var isBusy: Bool {
        phase == .loading || phase == .scanning || phase == .cleaning || phase == .reinstalling
    }

    private var chartSegments: [ChartSegment] {
        guard let usage, usage.total > 0 else { return [] }
        let sum = usage.slices.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        guard sum > 0 else { return [] }
        var acc = 0.0
        var out: [ChartSegment] = []
        for slice in usage.slices {
            let frac = Double(max(0, slice.bytes)) / Double(sum)
            out.append(ChartSegment(id: slice.id, start: acc, end: acc + frac, colorHex: slice.colorHex))
            acc += frac
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
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设备瘦身")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定开始瘦身？", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("删除选中的 \(selectedItems.count) 项", role: .destructive) { startClean() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除这些缓存与临时文件（预计释放 \(DeviceSlimService.formatBytes(selectedBytes))）。照片、聊天记录等用户数据不在清理范围内。")
        }
        .confirmationDialog("确定重装选中的 \(reinstallTargets.count) 款应用？",
                            isPresented: $confirmReinstall, titleVisibility: .visible) {
            Button("卸载并重装", role: .destructive) { startReinstall() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重装 = 先卸载再从「免登录下载」库里重新安装。**这些应用内的文稿与数据会被一起清除且无法恢复**（预计清理 \(DeviceSlimService.formatBytes(reinstallDocBytes)) 应用文档）。建议先备份。")
        }
        .task { await bootstrap() }
    }

    // MARK: - 1. 环形图 + 图例（同一张卡）

    private var overviewSection: some View {
        Section {
            if let usage {
                HStack(spacing: 14) {
                    Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(.blue)
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
                .padding(.vertical, 8)

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
            HStack {
                Text("空间占用情况")
                Spacer(minLength: 0)
                if let at = usage?.scannedAt {
                    Text(scanStamp(at))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func scanStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "上次扫描 hh:mm"
        return formatter.string(from: date)
    }

    private func legendRow(_ slice: DeviceSlimService.UsageSlice) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(slimHex: slice.colorHex)).frame(width: 9, height: 9)
            Text(slice.label).font(.subheadline)
            Spacer(minLength: 0)
            Text(DeviceSlimService.formatBytes(slice.bytes))
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: - 2. 警告

    private var warningBanner: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.footnote)
                Text("瘦身前请备份好重要数据，谨防数据丢失")
                    .font(.footnote).foregroundStyle(.orange)
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
                        .font(.footnote).foregroundStyle(.secondary)
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
                    Task { await runScan(force: true) }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise").font(.subheadline)
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
            Text(scanFooter).font(.caption2)
        }
    }

    private var scanFooter: String {
        if isBusy { return phase == .reinstalling ? "正在卸载并重装，请勿断开设备…" : "正在扫描设备…" }
        let count = selectableItems.count
        var text = count == 0
            ? "本机可达范围内没有需要清理的缓存（免越狱只清理媒体分区内可再生的缓存）。"
            : "共 \(count) 项可清理。"
        if fromCache { text += " 当前为缓存结果，点「重新扫描」可刷新。" }
        if !reinstallableApps.isEmpty {
            text += " 「较大应用」勾选 = 卸载重装（会清空该应用文稿与数据）。"
        }
        return text
    }

    // MARK: - 4. 分组

    private func groupSection(_ group: DeviceSlimService.Group) -> some View {
        Section {
            if group.items.isEmpty {
                Text(group.kind == .userLog ? "本机未发现可清理的日志" : "未发现可清理项")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if group.kind == .bigApps {
                if reinstallableApps.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).font(.footnote)
                        Text("这些应用本地都没有可重装的安装包（去「免登录下载」里下载一份即可重装）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(group.items) { item in
                    bigAppRow(item)
                }
                if !reinstallTargets.isEmpty {
                    Button {
                        confirmReinstall = true
                    } label: {
                        Label("重装选中的 \(reinstallTargets.count) 款（可清理 \(DeviceSlimService.formatBytes(reinstallDocBytes))）",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                    }
                }
            } else {
                ForEach(group.items) { item in
                    cacheRow(item)
                }
            }
        } header: {
            groupHeader(group)
        } footer: {
            if !group.items.isEmpty {
                Text(groupFooter(group)).font(.caption2)
            }
        }
    }

    private func groupHeader(_ group: DeviceSlimService.Group) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.kind.icon).font(.caption).foregroundStyle(.blue)
            Text(group.kind.rawValue)
            Spacer(minLength: 0)
            if group.kind == .bigApps {
                Text("共 \(group.items.count) 款 已选择重装 \(reinstallTargets.count) 款 可清理 \(DeviceSlimService.formatBytes(reinstallDocBytes)) 应用文档")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            } else if !group.items.isEmpty {
                Text("共 \(group.items.count) 项，已选择 \(DeviceSlimService.formatBytes(selectedBytesFor(group)))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func selectedBytesFor(_ group: DeviceSlimService.Group) -> Int64 {
        group.items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    private func groupFooter(_ group: DeviceSlimService.Group) -> String {
        switch group.kind {
        case .systemCache, .tempFiles: return group.kind.subtitle
        case .userLog: return "日志文件及过期的临时文件（免越狱只能清理媒体分区内可达的部分）"
        case .bigApps: return "通过批量重装应用，清理应用的冗余文稿和数据。重装会清空该应用的文稿与数据，且无法恢复。"
        }
    }

    private func cacheRow(_ item: DeviceSlimService.Item) -> some View {
        let on = selection.contains(item.id)
        return Button {
            if on { selection.remove(item.id) } else { selection.insert(item.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.body).foregroundStyle(on ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline).lineLimit(1)
                    if let detail = item.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(DeviceSlimService.formatBytes(item.bytes))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    /// 较大应用行（爱思表格：应用名称 / 应用大小 / 文档大小 / 操作）
    private func bigAppRow(_ item: DeviceSlimService.Item) -> some View {
        let available = item.ipaFileName != nil
        let on = reinstallSelection.contains(item.id)
        return Button {
            guard available else { return }
            if on { reinstallSelection.remove(item.id) } else { reinstallSelection.insert(item.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: available ? (on ? "checkmark.square.fill" : "square") : "square")
                    .font(.body)
                    .foregroundStyle(available ? (on ? .blue : .secondary) : Color.gray.opacity(0.35))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text("应用 \(DeviceSlimService.formatBytes(item.appSize))")
                        Text("·")
                        Text("文档 \(DeviceSlimService.formatBytes(item.docSize))")
                        if !available {
                            Text("资源缺失无法重装").foregroundStyle(.orange)
                        } else if item.isRisky {
                            Text("谨慎选择").foregroundStyle(.red)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(DeviceSlimService.formatBytes(item.docSize))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    // MARK: - 流程

    private func bootstrap() async {
        // 先用缓存秒开，再按需刷新
        if let cached = DeviceSlimService.cachedSnapshot() {
            await apply(snapshot: cached, fromCache: true)
        }
        await runScan(force: false)
    }

    private func apply(snapshot: DeviceSlimService.Snapshot, fromCache: Bool) async {
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                try DeviceSlimService.loadUsage(snapshot: snapshot)
            }.value
            usage = value
            let scanned = try await Task.detached(priority: .userInitiated) {
                try DeviceSlimService.scan(snapshot: snapshot)
            }.value
            groups = scanned
            selection = Set(scanned.filter { $0.kind.selectable }.flatMap(\.items).map(\.id))
            self.fromCache = fromCache
            phase = .ready
        } catch {
            errorText = "读取失败：\(error.localizedDescription)"
        }
    }

    private func runScan(force: Bool) async {
        if !force, let cached = DeviceSlimService.cachedSnapshot() {
            await apply(snapshot: cached, fromCache: true)
            return
        }
        phase = .scanning
        statusText = "正在扫描设备…"
        errorText = nil
        resultText = nil
        do {
            let snap = try await Task.detached(priority: .userInitiated) {
                try DeviceSlimService.buildSnapshot { message in
                    Task { @MainActor in statusText = message }
                }
            }.value
            await apply(snapshot: snap, fromCache: false)
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
                await runScan(force: true)
            } catch {
                phase = .ready
                errorText = "瘦身失败：\(error.localizedDescription)"
            }
        }
    }

    private func startReinstall() {
        let targets = reinstallTargets
        guard !targets.isEmpty else { return }
        phase = .reinstalling
        statusText = "正在卸载并重装…"
        Task {
            let result = await DeviceSlimService.reinstall(items: targets) { index, total, name in
                Task { @MainActor in statusText = "正在重装 \(index)/\(total)：\(name)" }
            }
            if result.ok.isEmpty && !result.failures.isEmpty {
                errorText = result.failures.prefix(3).joined(separator: "\n")
            } else {
                resultText = "已重装 \(result.ok.count) 款"
                    + (result.failures.isEmpty ? "" : "（\(result.failures.count) 款失败）")
                errorText = result.failures.isEmpty ? nil : result.failures.prefix(3).joined(separator: "\n")
            }
            reinstallSelection.removeAll()
            phase = .finished
            await runScan(force: true)
        }
    }
}

// MARK: - 环形图

private struct DeviceSlimDonut: View {
    let segments: [DeviceSlimView.ChartSegment]

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemGray5), lineWidth: 24)
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
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(start * 360 - 90),
                    endAngle: .degrees(end * 360 - 90),
                    clockwise: false)
        return path
    }
}

private extension Color {
    init(slimHex hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
