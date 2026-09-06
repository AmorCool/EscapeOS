import SwiftUI

/// v0.3.199：电池健康面板 —— diagnostics_relay IORegistry 读取（非越狱可读）。
/// 参考 iDescriptor BatteryInfo 面板：循环/设计容量/最大容量/健康度/序列号/充电状态。
struct BatteryHealthView: View {
    @State private var isLoading = true
    @State private var info: BatteryHealthInfo?
    @State private var errorText: String?
    @State private var lastUpdated: Date?
    /// v0.3.202：实时更新 —— 定时轮询（10s），离开页面取消
    @State private var pollTask: Task<Void, Never>?

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
            // v0.3.202：实时轮询 —— 用 Task 检查取消；struct 不能用 [weak self]
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

    /// silent：静默刷新不闪 ProgressView（轮询用）
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

    /// 健康度环形展示（蓝→黄→橙按百分比）
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

    private func healthLabel(_ health: Int) -> String {
        switch health {
        case 90...: return "电池状况良好"
        case 80..<90: return "电池状况正常"
        case 70..<80: return "电池已略微损耗"
        default: return "建议更换电池"
        }
    }

    private func metricsGrid(info: BatteryHealthInfo) -> some View {
        let rows: [(String, String)] = [
            ("循环次数", info.cycleCount.map { "\($0) 次" } ?? "—"),
            ("设计容量", info.designCapacity.map { "\($0) mAh" } ?? "—"),
            ("最大容量", info.maxCapacity.map { "\($0) mAh" } ?? "—"),
            ("当前电量", info.currentCapacity.map { "\($0) mAh" } ?? "—"),
            ("充电状态", chargingLabel(info)),
            ("序列号", info.serial ?? "—"),
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

    private func chargingLabel(_ info: BatteryHealthInfo) -> String {
        if info.fullyCharged == true { return "已充满" }
        if info.isCharging == true { return "充电中" }
        return "未充电"
    }

    private var errorCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "battery.0percent")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("无法读取电池数据")
                .font(.headline)
            Text(errorText ?? "未知错误")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
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