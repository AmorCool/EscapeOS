import SwiftUI
import UIKit

/// v0.3.307：设备信息面板的**小块视图**集合。
///
/// **为什么要拆**（真机崩溃取证）：设备信息页原先在一个 `body` 里堆了 11 个
/// `@ViewBuilder` 分组 + 一个 `Group`，编译出的嵌套泛型类型极深。真机崩溃日志
/// （iOS 27 / LiveProcess-2026-09-11-163343.ips）显示主线程在
/// `swift_getTypeByMangledName → decodeMangledType → decodeGenericArgs` 递归里
/// 撞栈保护页（EXC_BAD_ACCESS / SIGILL，"Could not determine thread index for
/// stack guard region"）——即 **Swift 运行时解析这个超深 `some View` 类型时栈溢出**。
/// 触发点是 NavigationStack push 该页（`configurePreferredTransition` →
/// `_preferenceValue` → `ViewBodyAccessor.updateBody` → 我们的 body）。
///
/// 解法：把「行/分组」从**视图构造**改成**数据**（`[DeviceInfoSectionSpec]`），
/// 每个分组只由本文件的独立 `View` 结构体渲染。这样页面 body 的类型深度恒定，
/// 与字段多少无关；以后再加字段也不会再触发同类崩溃。
struct DeviceInfoRowSpec: Identifiable {
    let id: Int
    let label: String
    let value: String?
    /// 敏感字段（序列号/UDID/IMEI…）：全局小眼睛控制显隐 + 可复制
    let sensitive: Bool
    /// v0.3.322：该行要打开的链接（如「保修期限」→ Apple 官方保修查询页）；
    /// 有值时行尾显示「查询 ›」，点按交给页面用内置浏览器打开。
    var link: String? = nil

    init(id: Int, label: String, value: String?, sensitive: Bool, link: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.sensitive = sensitive
        self.link = link
    }
}

struct DeviceInfoSectionSpec: Identifiable {
    let title: String
    let icon: String
    let rows: [DeviceInfoRowSpec]
    var id: String { title }
}

/// 单个信息行
private struct DeviceInfoRowView: View {
    let row: DeviceInfoRowSpec
    let showSensitive: Bool
    let onCopy: (String) -> Void
    let onOpenLink: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Text(row.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            if row.sensitive {
                sensitiveValue
            } else {
                Text(row.value ?? "—")
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if let link = row.link, !link.isEmpty {
                Button {
                    onOpenLink?(link)
                } label: {
                    HStack(spacing: 2) {
                        Text("查询").font(.caption)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
    }

    private var sensitiveValue: some View {
        HStack(spacing: 6) {
            Text(displayText)
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let v = row.value, !v.isEmpty {
                Button {
                    onCopy(v)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制 \(row.label)")
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.4) {
            if let v = row.value, !v.isEmpty { onCopy(v) }
        }
    }

    private var displayText: String {
        guard let v = row.value, !v.isEmpty else { return "—" }
        if showSensitive { return v }
        return String(repeating: "•", count: min(v.count, 14))
    }
}

/// 一个分组卡片（标题 + 若干行）
struct DeviceInfoSectionCard: View {
    let section: DeviceInfoSectionSpec
    let showSensitive: Bool
    let onCopy: (String) -> Void
    var onOpenLink: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: section.icon).foregroundStyle(.blue)
                Text(section.title).font(.headline)
            }
            .padding(.bottom, 8)
            // v0.3.308：没有值的行直接不显示（此前一律渲染成「—」，整页出现大量空行）
            ForEach(section.rows) { row in
                // 没有值但有链接的行照样显示（如「保修期限 → 查询」）；
                // 既没值也没链接的行才隐藏（此前一律渲染成「—」）
                if (row.value ?? "").isEmpty == false || (row.link ?? "").isEmpty == false {
                    DeviceInfoRowView(row: row, showSensitive: showSensitive,
                                      onCopy: onCopy, onOpenLink: onOpenLink)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// 纯文字卡片（功能支持列表）
struct DeviceInfoTextCard: View {
    let title: String
    let icon: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.blue)
                Text(title).font(.headline)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// 设备原始数据（默认折叠）
struct DeviceInfoRawCard: View {
    let values: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, pair in
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
                    Text("设备原始数据（\(values.count) 项）").font(.headline)
                }
            }
            .tint(.primary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// 存储分组里的「硬盘详情」入口（固定目的地，无泛型参数）
struct StorageDetailLinkCard: View {
    var body: some View {
        NavigationLink {
            StorageDetailView()
        } label: {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "internaldrive.fill", tint: .blue, symbolSize: 17, frameSize: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("硬盘详情").font(.subheadline.weight(.medium))
                    Text("闪存颗粒 / 控制器 / 擦写参数").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }
}
