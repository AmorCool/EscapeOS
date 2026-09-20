//
//  AirliftPocModuleUI.swift
//  EscapeSpace
//
//  airlift-poc 模块的原生界面. 卡片式布局，配色全部走系统语义色，跟随系统深浅色.
//
//  ## 这个模块为什么这么写
//  它只声明 requires，然后调宿主能力（HostCapabilityService.call）. 将来漏洞链被替换
//  （airlift -> 下一个），本文件一行都不用改.
//
//  ## 界面三条硬规则（用户明确要求，改之前先看这三条）
//  1. 不用黄色感叹号 —— 不用 ⚠️，也不用 exclamationmark.triangle
//  2. 注释是给开发者看的，界面上一个字都不显示（StepText.clean 负责清掉）
//  3. 句号一律用英文 `.`，给用户看的描述要精简
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 设计系统

/// 模块内视觉常量. 只放尺寸，颜色一律用系统语义色（不写死深浅色）.
private enum Look {
    static let radius: CGFloat = 14
    static let pad: CGFloat = 14
    static let gap: CGFloat = 10
    /// 卡片背景：跟随分组背景色，深浅色自动
    static var cardFill: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    /// 页面底色
    static var pageFill: Color { Color(uiColor: .systemGroupedBackground) }
}

/// 顶部大卡：图标 + 标题 + 副标题 + 右侧状态胶囊.
struct HeroCard: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    var tint: Color = .accentColor
    var pill: (text: String, color: Color)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if let pill {
                Pill(text: pill.text, color: pill.color)
            }
        }
        .padding(Look.pad)
        .background(Look.cardFill, in: RoundedRectangle(cornerRadius: Look.radius, style: .continuous))
    }
}

/// 普通卡片容器.
struct CardBox<Content: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: Look.gap) { content() }
        }
        .padding(Look.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.cardFill, in: RoundedRectangle(cornerRadius: Look.radius, style: .continuous))
    }
}

/// 状态胶囊.
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// 圆角动作按钮.
struct CardButton: View {
    enum Kind { case normal, danger
        var tint: Color { self == .danger ? .red : .accentColor }
    }
    let title: String
    let icon: String
    var kind: Kind = .normal
    var enabled: Bool = true
    var busy: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .medium))
                }
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(enabled ? kind.tint : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(kind.tint.opacity(enabled ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}

/// 左标签 / 右值（值用等宽，方便看路径与数字）.
struct KV: View {
    let label: String
    let value: String
    var mono: Bool = false
    var color: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundColor(color ?? .primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

/// 输入框（等宽，自动纠正关闭）.
struct PathField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// 结果 / 错误横幅（圆角，不用感叹号）.
struct BannerView: View {
    enum Kind { case ok, warn, error
        var color: Color {
            switch self {
            case .ok: return .green
            case .warn: return .orange
            case .error: return .red
            }
        }
        var icon: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warn: return "info.circle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: kind.icon).foregroundColor(kind.color)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 步骤文本清洗

/// 把能力返回的「步骤」原文清成**给人看的短句**.
///
/// 能力返回的步骤里带大量给开发者的解释：`⚠️`、`★`、markdown 的 `**` 与反引号、
/// 以及括号里那串「为什么 / 判据 / 边界」. 那些在**日志**里有用，在**界面**上是噪音.
/// 这里只留「做了什么、成没成」；原文照样能在展开后的「全部行」和日志里看到.
enum StepText {
    static func clean(_ raw: String) -> String {
        var t = raw
        for junk in ["⚠️", "\u{FE0F}", "★", "**", "`", "❌", "✅"] {
            t = t.replacingOccurrences(of: junk, with: "")
        }
        for pair in [("（", "）"), ("(", ")")] {
            while let open = t.firstIndex(of: Character(pair.0)),
                  let close = t[t.index(after: open)...].firstIndex(of: Character(pair.1)) {
                t.removeSubrange(open...close)
            }
        }
        t = t.split(separator: " ").joined(separator: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 单条步骤：小圆点 + 文本.
struct StepRow: View {
    let text: String
    var raw: Bool = false

    private var shown: String { raw ? text : StepText.clean(text) }
    private var isWarn: Bool {
        text.contains("失败") || text.contains("拒绝") || text.contains("未成立")
            || text.contains("不一致") || text.contains("缺位")
    }
    private var isGood: Bool {
        text.contains("已") || text.contains("成立") || text.contains("成功")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isWarn ? Color.orange : (isGood ? Color.green : Color.secondary.opacity(0.45)))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(shown.isEmpty ? text : shown)
                .font(.system(size: 12))
                .foregroundColor(isWarn ? .orange : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 步骤列表：默认只显示关键行，技术判据折起来.
struct CompactStepsView: View {
    let steps: [String]
    @State private var expanded = false

    /// 噪音行标记 —— 命中即默认折叠（不是删除）
    private static let noise: [String] = [
        "判据①", "判据②", "判据③", "books staging", "Grappa 实验",
        "Media 根前若干项", "规范化 base", "linkIdentifier", "targetIdentifier",
        "清单第", "帧前32字节", "响应 #", "已发 ", "攻击标识符",
        "AssetID =", "linkDestination =", "读目标（", "搬回的条目（",
        "【Grappa", "结论 下一步", "结论 本次",
    ]

    private var keySteps: [String] {
        steps.filter { line in !Self.noise.contains { line.contains($0) } }
    }

    var body: some View {
        if !steps.isEmpty {
            CardBox(title: "执行步骤", icon: "list.bullet") {
                ForEach(Array((expanded ? steps : keySteps).enumerated()), id: \.offset) { _, step in
                    StepRow(text: step, raw: expanded)
                }
                if keySteps.count < steps.count {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            Text(expanded ? "收起技术细节" : "显示全部 \(steps.count) 行")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 调用记录器

/// 宿主能力调用的内存记录（日志 tab 的兜底；主来源是 CapabilityLog/run.log）.
@MainActor
final class AirliftPocLog: ObservableObject {
    static let shared = AirliftPocLog()

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let capability: String
        let args: String
        let result: String
        let ok: Bool
    }

    @Published private(set) var entries: [Entry] = []

    private static let maxTextLength = 4000

    private init() {}

    func record(capability: String, args: String, result: String, ok: Bool) {
        entries.insert(Entry(time: Date(),
                             capability: capability,
                             args: Self.clip(args),
                             result: Self.clip(result),
                             ok: ok),
                       at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }

    func clear() { entries.removeAll() }

    private static func clip(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        return String(text.prefix(maxTextLength)) + "\n…（已截断，原文 \(text.count) 字符）"
    }

    /// 统一的调用入口：调宿主能力并自动记一条内存日志.
    ///
    /// 同步阻塞：沙盒外操作走 airlift，一次 10~20 秒，调用方必须在后台线程调.
    nonisolated static func callRaw(_ capability: String, _ jsonArgs: String) -> (rc: Int32, json: String) {
        let result = HostCapabilityService.call(capability: capability, jsonArgs: jsonArgs)
        let ok = result.0 == 0
        Task { @MainActor in
            AirliftPocLog.shared.record(capability: capability,
                                        args: jsonArgs,
                                        result: result.1,
                                        ok: ok)
        }
        return (result.0, result.1)
    }
}

// MARK: - JSON 小工具

/// 从能力返回值里安全取值. 刻意不用 Codable：宿主返回会加字段，用字典读能向前兼容，
/// 解析失败时也能把原文交给界面（排障时原文比「解析失败」有用得多）.
private enum CapJSON {
    static func dict(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }
    static func bool(_ dict: [String: Any]?, _ key: String) -> Bool? { dict?[key] as? Bool }
    static func string(_ dict: [String: Any]?, _ key: String) -> String? { dict?[key] as? String }
    static func int(_ dict: [String: Any]?, _ key: String) -> Int? { dict?[key] as? Int }
    static func strings(_ dict: [String: Any]?, _ key: String) -> [String] {
        dict?[key] as? [String] ?? []
    }
    static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
    static func byteText(_ size: Int) -> String {
        if size >= 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576) }
        if size >= 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return "\(size) B"
    }
}

/// 页面容器：滚动 + 卡片间距 + 统一底色.
private struct Page<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(spacing: 14) { content() }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
        }
        .background(Look.pageFill)
    }
}

// MARK: - 注册入口

/// 把 airlift-poc 的原生界面注册进宿主.
/// 调用点：`registerBuiltinModuleUIs()`（`EscapeSpaceApp.init()` 里触发）.
@MainActor
func registerAirliftPocModuleUI() {
    ModuleUIRegistry.shared.register("airlift-poc") { module in
        [
            ModuleUITab(id: "overview", title: "概览",
                        systemImage: "gauge.with.dots.needle.33percent") { m in
                AirliftOverviewTab(module: m)
            },
            ModuleUITab(id: "files", title: "文件",
                        systemImage: "folder") { m in
                AirliftFilesTab(module: m)
            },
            ModuleUITab(id: "overwrite", title: "写入",
                        systemImage: "square.and.arrow.down") { m in
                AirliftOverwriteTab(module: m)
            },
            ModuleUITab(id: "supervised", title: "监督模式",
                        systemImage: "lock.shield") { m in
                AirliftSupervisedTab(module: m)
            },
            ModuleUITab(id: "theme", title: "主题",
                        systemImage: "keyboard") { m in
                AirliftThemeTab(module: m)
            },
            ModuleUITab(id: "log", title: "日志",
                        systemImage: "text.alignleft") { m in
                AirliftLogTab()
            },
        ]
    }
}

// MARK: - 概览

private struct AirliftOverviewTab: View {
    let module: EscapeModule

    @State private var hostVersion = "…"
    @State private var hostBuild = ""
    @State private var airliftRunnable: Bool?
    @State private var airliftEnabled: Bool?
    @State private var exploitNote = ""
    @State private var supportedCapabilities: [String] = []
    @State private var loading = false

    var body: some View {
        Page {
            HeroCard(icon: "bolt.horizontal.circle.fill",
                     title: module.name,
                     subtitle: "v\(module.version) · 通过宿主能力接口工作",
                     tint: .purple,
                     pill: module.blockingIssues.isEmpty
                        ? ("可用", .green)
                        : ("不可用", .orange))

            if !module.blockingIssues.isEmpty {
                CardBox(title: "为什么不可用", icon: "info.circle") {
                    ForEach(module.blockingIssues, id: \.self) { issue in
                        Text(issue).font(.system(size: 12)).foregroundColor(.orange)
                    }
                }
            }

            CardBox(title: "宿主", icon: "iphone") {
                KV(label: "版本",
                   value: hostBuild.isEmpty ? hostVersion : "\(hostVersion) (\(hostBuild))",
                   mono: true)
                KV(label: "airlift（本模块读写）",
                   value: airliftRunnable == nil ? "查询中…" : (airliftRunnable! ? "可用" : "不可用"),
                   color: airliftRunnable == nil ? .secondary : (airliftRunnable! ? .green : .orange))
                KV(label: "「漏洞利用」里的 airlift",
                   value: airliftEnabled == nil ? "查询中…" : (airliftEnabled! ? "已启用" : "未启用"),
                   color: airliftEnabled == nil ? .secondary : (airliftEnabled! ? .green : .orange))
                if !exploitNote.isEmpty {
                    Text(exploitNote)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            CardBox(title: "本模块声明的能力", icon: "checklist") {
                if supportedCapabilities.isEmpty {
                    Text(loading ? "查询中…" : "未取到能力清单")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    ForEach(module.requires ?? [], id: \.self) { cap in
                        HStack(spacing: 8) {
                            Image(systemName: supportedCapabilities.contains(cap)
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(supportedCapabilities.contains(cap) ? .green : .red)
                            Text(cap).font(.system(size: 12, design: .monospaced))
                            Spacer(minLength: 0)
                            if !supportedCapabilities.contains(cap) {
                                Text("缺失").font(.system(size: 11)).foregroundColor(.red)
                            }
                        }
                    }
                }
            }

            CardButton(title: loading ? "查询中…" : "刷新", icon: "arrow.clockwise",
                       busy: loading) {
                Task { await refresh() }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        let versionDict = CapJSON.dict(await call("host.version"))
        hostVersion = CapJSON.string(versionDict, "version") ?? "未知"
        hostBuild = CapJSON.string(versionDict, "build") ?? ""

        supportedCapabilities = CapJSON.strings(CapJSON.dict(await call("host.capabilities")), "list")

        let exploitDict = CapJSON.dict(await call("exploit.status"))
        airliftRunnable = CapJSON.bool(exploitDict, "airliftRunnable")
        airliftEnabled = CapJSON.bool(exploitDict, "airliftEnabled")
        exploitNote = CapJSON.string(exploitDict, "note") ?? ""
    }

    /// 宿主能力是同步阻塞的（沙盒外走 airlift 十几秒），所以放后台线程.
    private func call(_ capability: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (_, json) = AirliftPocLog.callRaw(capability, "{}")
                continuation.resume(returning: json)
            }
        }
    }
}

// MARK: - 文件（AFC 两个根）

private struct AirliftFilesTab: View {
    let module: EscapeModule

    @State private var root = "media"
    @State private var path = "/"
    @State private var entries: [AfcEntry] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var previewName = ""
    @State private var previewText = ""
    @State private var previewLoading = false
    @State private var deleteName = ""
    @State private var confirmingDelete = false
    @State private var newFolderName = ""
    @State private var statPath = ""
    @State private var statResult = ""

    private struct AfcEntry: Identifiable {
        let name: String
        let path: String
        let isDir: Bool
        let size: Int
        var id: String { path }
    }

    private var rootDisplay: String {
        root == "crash" ? "/var/mobile/Library/Logs/CrashReporter" : "/var/mobile/Media"
    }

    var body: some View {
        Page {
            HeroCard(icon: "folder.fill",
                     title: "文件",
                     subtitle: "AFC 的两个根：Media 与 CrashReporter",
                     tint: .accentColor,
                     pill: (root == "crash" ? "CrashReporter" : "Media", .accentColor))

            CardBox(title: "位置", icon: "externaldrive") {
                Picker("根", selection: $root) {
                    Text("/var/mobile/Media").tag("media")
                    Text("CrashReporter").tag("crash")
                }
                .pickerStyle(.segmented)
                .onChange(of: root) { _ in
                    path = "/"
                    Task { await load() }
                }
                Text(path == "/" ? rootDisplay : path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                HStack(spacing: 8) {
                    CardButton(title: "上一级", icon: "arrow.up",
                               enabled: path != "/" && !loading) {
                        Task { await goUp() }
                    }
                    CardButton(title: "刷新", icon: "arrow.clockwise",
                               busy: loading) {
                        Task { await load() }
                    }
                }
            }

            if let errorText { BannerView(kind: .error, text: errorText) }

            CardBox(title: "内容（\(entries.count) 项）", icon: "list.bullet") {
                if entries.isEmpty && !loading {
                    Text("空目录").font(.system(size: 12)).foregroundColor(.secondary)
                }
                ForEach(entries) { entry in
                    HStack(spacing: 9) {
                        Image(systemName: entry.isDir ? "folder.fill" : "doc")
                            .font(.system(size: 12))
                            .foregroundColor(entry.isDir ? .accentColor : .secondary)
                        Button {
                            if entry.isDir {
                                Task { await enter(entry) }
                            } else {
                                Task { await preview(entry) }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(entry.name)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if !entry.isDir {
                                    Text(CapJSON.byteText(entry.size))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            deleteName = entry.name
                            confirmingDelete = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            CardBox(title: "新建目录", icon: "folder.badge.plus") {
                PathField(placeholder: "目录名", text: $newFolderName)
                CardButton(title: "创建", icon: "plus",
                           enabled: !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await makeFolder() }
                }
            }

            CardBox(title: "探测任意路径（零 airlift）", icon: "scope") {
                Text("Media 之外读/写/列都会被沙盒拒，但 **stat 能过** —— 一次 AFC 往返、几十毫秒.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PathField(placeholder: "相对当前根的路径，可含 ..", text: $statPath)
                CardButton(title: "查一下", icon: "magnifyingglass") {
                    Task { await doStat() }
                }
                if !statResult.isEmpty {
                    Text(statResult)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            CardBox(title: "说明", icon: "info.circle") {
                Text("本页走 AFC（不是 airlift），在 Media 与 CrashReporter 上是完整文件管理器.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text("Media 之外：只有「单个已知文件」能读写（见「写入」页）；列目录做不到.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: Binding(get: { !previewName.isEmpty },
                                    set: { if !$0 { previewName = "" } })) {
            previewSheet
        }
        .confirmationDialog("删除 \(deleteName)？", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteEntry() } }
            Button("取消", role: .cancel) {}
        }
        .task { await load() }
    }

    private var previewSheet: some View {
        NavigationStack {
            ScrollView {
                Text(previewLoading ? "读取中…" : previewText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
            .navigationTitle(previewName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { previewName = "" }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let json = await call("afc.list", CapJSON.json(["root": root, "path": path]))
        let dict = CapJSON.dict(json)
        guard CapJSON.bool(dict, "ok") == true else {
            errorText = CapJSON.string(dict, "error") ?? json
            entries = []
            return
        }
        errorText = nil
        let raw = (dict?["entries"] as? [[String: Any]]) ?? []
        entries = raw.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return AfcEntry(name: name,
                            path: (item["path"] as? String) ?? name,
                            isDir: (item["isDir"] as? Bool) ?? false,
                            size: (item["size"] as? Int) ?? 0)
        }.sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }

    private func enter(_ entry: AfcEntry) async {
        path = entry.path.hasPrefix("/") ? entry.path : "/" + entry.path
        await load()
    }

    private func goUp() async {
        var comps = path.split(separator: "/").map(String.init)
        if !comps.isEmpty { comps.removeLast() }
        path = comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
        await load()
    }

    private func preview(_ entry: AfcEntry) async {
        previewName = entry.name
        previewLoading = true
        previewText = ""
        defer { previewLoading = false }
        let json = await call("afc.read", CapJSON.json(["root": root,
                                                        "path": entry.path,
                                                        "encoding": "utf8"]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") == true {
            previewText = CapJSON.string(dict, "data") ?? ""
        } else {
            previewText = CapJSON.string(dict, "error") ?? json
        }
    }

    private func deleteEntry() async {
        let json = await call("afc.delete", CapJSON.json(["root": root,
                                                          "path": path + "/" + deleteName]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") != true {
            errorText = CapJSON.string(dict, "error") ?? json
        }
        deleteName = ""
        await load()
    }

    private func makeFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let base = path == "/" ? "" : path
        let json = await call("afc.mkdir", CapJSON.json(["root": root, "path": "\(base)/\(name)"]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") == true {
            newFolderName = ""
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
        }
        await load()
    }

    private func doStat() async {
        let p = statPath.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        let json = await call("afc.stat", CapJSON.json(["root": root, "path": p]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "exists") == true {
            statResult = "存在 · \(CapJSON.string(dict, "ifmt") ?? "?")"
                + " · \(CapJSON.byteText(CapJSON.int(dict, "size") ?? 0))"
        } else {
            statResult = CapJSON.string(dict, "describe")
                ?? CapJSON.string(dict, "error") ?? "取不到"
        }
    }

    private func call(_ capability: String, _ args: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (_, json) = AirliftPocLog.callRaw(capability, args)
                continuation.resume(returning: json)
            }
        }
    }
}

// MARK: - 写入（AIR + airlift）

private struct AirliftOverwriteTab: View {
    let module: EscapeModule

    @State private var target = ""
    @State private var airFiles: [AirFile] = []
    @State private var selectedAirName: String?
    @State private var targetIsDirectory = false
    @State private var leafName = ""
    @State private var backupFirst = true
    @State private var working = false
    @State private var importing = false
    @State private var confirming = false
    @State private var confirmingDelete = false
    @State private var steps: [String] = []
    @State private var errorText: String?
    @State private var okText: String?

    private struct AirFile: Identifiable {
        let name: String
        let size: Int
        var id: String { name }
    }

    var body: some View {
        Page {
            HeroCard(icon: "square.and.arrow.down.fill",
                     title: "写入",
                     subtitle: "用 AIR 里的文件覆盖沙盒外的任意路径",
                     tint: .orange,
                     pill: (working ? "执行中" : "就绪", working ? .orange : .green))

            CardBox(title: "目标", icon: "scope") {
                PathField(placeholder: "/var/mobile/... 绝对路径", text: $target)
                Toggle("目标是目录（写到它下面）", isOn: $targetIsDirectory)
                    .font(.system(size: 13))
                if targetIsDirectory {
                    PathField(placeholder: "文件名（留空 = 用源文件名）", text: $leafName)
                }
                Text(targetIsDirectory
                     ? "落点 = 目标目录 / 文件名"
                     : "落点 = 你填的这个路径本身")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            CardBox(title: "源文件（AIR）", icon: "tray.full") {
                if airFiles.isEmpty {
                    Text("AIR 里还没有文件. 点下面导入，或先用「读取」把目标拉回来.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                ForEach(airFiles) { file in
                    HStack(spacing: 9) {
                        Button {
                            selectedAirName = file.name
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: selectedAirName == file.name
                                      ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(selectedAirName == file.name
                                                     ? .accentColor : .secondary)
                                Text(file.name)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(CapJSON.byteText(file.size))
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task { await deleteAirFile(file.name) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12)).foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                CardButton(title: "从本机选择文件导入到 AIR", icon: "square.and.arrow.down") {
                    importing = true
                }
                CardButton(title: "把目标读回来（不改动目标）", icon: "arrow.down.doc",
                           enabled: !target.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await pullToAir() }
                }
            }

            CardBox(title: "动作", icon: "bolt") {
                Toggle("覆盖前先把目标备份到 AIR（.bak）", isOn: $backupFirst)
                    .font(.system(size: 13))
                CardButton(title: "覆盖目标", icon: "square.and.arrow.up.on.square",
                           enabled: selectedAirName != nil
                                 && !target.trimmingCharacters(in: .whitespaces).isEmpty) {
                    confirming = true
                }
                CardButton(title: "删除目标文件", icon: "trash", kind: .danger,
                           enabled: !target.trimmingCharacters(in: .whitespaces).isEmpty) {
                    confirmingDelete = true
                }
            }

            if let okText { BannerView(kind: .ok, text: okText) }
            if let errorText { BannerView(kind: .error, text: errorText) }

            CompactStepsView(steps: steps)
        }
        .task { await refreshAirList() }
        .documentPicker(isPresented: $importing,
                        allowedTypes: [.item],
                        allowsMultipleSelection: false) { urls in
            Task { await importPicked(urls) }
        }
        .confirmationDialog("确认覆盖？", isPresented: $confirming, titleVisibility: .visible) {
            Button("覆盖", role: .destructive) { Task { await overwrite() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将用 AIR/\(selectedAirName ?? "?") 覆盖 \(target)."
                 + (backupFirst ? "覆盖前会先备份原内容." : "已关闭备份."))
        }
        .confirmationDialog("确认删除？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteTarget() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将彻底删除 \(target). 备份会留在 App 沙盒的 LoginLogs/ 下.")
        }
    }

    private func call(_ capability: String, _ args: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (_, json) = AirliftPocLog.callRaw(capability, args)
                continuation.resume(returning: json)
            }
        }
    }

    private func refreshAirList() async {
        let dict = CapJSON.dict(await call("airlift.air", CapJSON.json(["op": "list"])))
        let raw = (dict?["entries"] as? [[String: Any]]) ?? []
        airFiles = raw.compactMap { item in
            guard let name = item["name"] as? String,
                  (item["isDir"] as? Bool) != true else { return nil }
            return AirFile(name: name, size: (item["size"] as? Int) ?? 0)
        }
        if let selected = selectedAirName, !airFiles.contains(where: { $0.name == selected }) {
            selectedAirName = nil
        }
    }

    private func deleteAirFile(_ name: String) async {
        let dict = CapJSON.dict(await call("airlift.air",
                                           CapJSON.json(["op": "delete", "name": name])))
        if CapJSON.bool(dict, "ok") != true {
            errorText = CapJSON.string(dict, "error") ?? ""
        }
        if selectedAirName == name { selectedAirName = nil }
        await refreshAirList()
    }

    /// 导入用户选的文件到 AIR.
    ///
    /// 入参是**已经在 App 沙盒里**的 URL —— SharedDocumentPicker 用 asCopy: true，
    /// 系统拷完才回调，所以不要再调 startAccessingSecurityScopedResource.
    private func importPicked(_ urls: [URL]) async {
        guard let url = urls.first else { return }
        guard let data = try? Data(contentsOf: url) else {
            errorText = "读不到所选文件：\(url.lastPathComponent)"
            return
        }
        let args = CapJSON.json(["op": "write",
                                 "name": url.lastPathComponent,
                                 "data": data.base64EncodedString(),
                                 "encoding": "base64"])
        let dict = CapJSON.dict(await call("airlift.air", args))
        if CapJSON.bool(dict, "ok") == true {
            okText = "已导入 \(url.lastPathComponent)"
            errorText = nil
            await refreshAirList()
        } else {
            errorText = CapJSON.string(dict, "error") ?? ""
        }
    }

    private func pullToAir() async {
        working = true
        steps = []
        errorText = nil
        okText = nil
        defer { working = false }
        let p = target.trimmingCharacters(in: .whitespaces)
        let json = await call("airlift.pull", CapJSON.json(["path": p]))
        let dict = CapJSON.dict(json)
        steps = CapJSON.strings(dict, "steps")
        if CapJSON.bool(dict, "ok") == true {
            okText = "已读到 AIR：\(CapJSON.string(dict, "airName") ?? "?")"
            await refreshAirList()
            if let name = CapJSON.string(dict, "airName"), !name.isEmpty {
                selectedAirName = name
            }
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
        }
    }

    private func deleteTarget() async {
        working = true
        steps = []
        errorText = nil
        okText = nil
        defer { working = false }
        let p = target.trimmingCharacters(in: .whitespaces)
        let json = await call("airlift.delete", CapJSON.json(["path": p]))
        let dict = CapJSON.dict(json)
        steps = CapJSON.strings(dict, "steps")
        if CapJSON.bool(dict, "ok") == true {
            okText = "已删除 \(p)"
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
        }
    }

    private func overwrite() async {
        working = true
        steps = []
        errorText = nil
        okText = nil
        defer { working = false }
        var payload: [String: Any] = [
            "target": target.trimmingCharacters(in: .whitespaces),
            "airName": selectedAirName ?? "",
            "backup": backupFirst,
        ]
        if targetIsDirectory {
            payload["targetIsDirectory"] = true
            let leaf = leafName.trimmingCharacters(in: .whitespaces)
            if !leaf.isEmpty { payload["leafName"] = leaf }
        }
        let json = await call("airlift.overwrite", CapJSON.json(payload))
        let dict = CapJSON.dict(json)
        steps = CapJSON.strings(dict, "steps")
        if CapJSON.bool(dict, "ok") == true {
            okText = "已写入 \(CapJSON.string(dict, "target") ?? "")"
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
        }
    }
}

// MARK: - 监督模式

private struct AirliftSupervisedTab: View {
    let module: EscapeModule

    @State private var isSupervised: Bool?
    @State private var organizationName = ""
    @State private var running = false
    @State private var loading = false
    @State private var confirming = false
    @State private var steps: [String] = []
    @State private var errorText: String?

    var body: some View {
        Page {
            HeroCard(icon: isSupervised == true ? "lock.shield.fill" : "lock.open",
                     title: "监督模式",
                     subtitle: isSupervised == nil ? "读取中…"
                             : (isSupervised! ? "已开启" : "未开启"),
                     tint: isSupervised == true ? .green : .secondary,
                     pill: (isSupervised == nil ? "…" : (isSupervised! ? "开" : "关"),
                            isSupervised == true ? .green : .secondary))

            CardBox(title: "结论先说", icon: "info.circle") {
                Text("这个目标做不到. 真机实测：CloudConfigurationDetails.plist 在 SystemGroup 容器里，"
                     + "沙盒只允许读/移出、拒绝创建/写入 —— 读得到 412 字节，但覆盖读回一点没变，"
                     + "连在同一个目录里新建一个文件都建不出来.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("对照：/var/mobile/Library/** 下的文件可以正常覆盖.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            CardBox(title: "当前状态", icon: "shield") {
                KV(label: "IsSupervised",
                   value: isSupervised == nil ? "读取中…" : (isSupervised! ? "true" : "false"),
                   mono: true,
                   color: isSupervised == true ? .green : .secondary)
                PathField(placeholder: "组织名称（可选）", text: $organizationName)
                CardButton(title: "重新读取", icon: "arrow.clockwise", busy: loading) {
                    Task { await readState() }
                }
            }

            CardBox(title: "操作", icon: "bolt") {
                CardButton(title: isSupervised == true ? "关闭监督模式" : "启用监督模式",
                           icon: isSupervised == true ? "lock.open.fill" : "lock.shield.fill",
                           enabled: isSupervised != nil && !running,
                           busy: running) {
                    confirming = true
                }
                Text("流程：读回原文件 -> 把原字节写回原位 -> 覆盖新内容 -> 读回校验. 约 50~100 秒.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            if let errorText { BannerView(kind: .error, text: errorText) }
            CompactStepsView(steps: steps)
        }
        .task { await readState() }
        .confirmationDialog(isSupervised == true ? "确认关闭监督模式？" : "确认启用监督模式？",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(isSupervised == true ? "关闭" : "启用", role: .destructive) {
                Task { await apply(!(isSupervised ?? false)) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func readState() async {
        loading = true
        defer { loading = false }
        let dict = CapJSON.dict(await call("sys.supervised.get", "{}"))
        if let value = CapJSON.bool(dict, "isSupervised") {
            isSupervised = value
            if let org = CapJSON.string(dict, "organizationName"), !org.isEmpty {
                organizationName = org
            }
            errorText = nil
        } else {
            isSupervised = nil
            errorText = CapJSON.string(dict, "error") ?? ""
        }
    }

    private func apply(_ enabled: Bool) async {
        running = true
        steps = []
        errorText = nil
        defer { running = false }
        var payload: [String: Any] = ["enabled": enabled]
        let trimmed = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled, !trimmed.isEmpty { payload["organizationName"] = trimmed }
        let dict = CapJSON.dict(await call("sys.supervised.set", CapJSON.json(payload)))
        steps = CapJSON.strings(dict, "steps")
        if CapJSON.bool(dict, "ok") != true {
            errorText = CapJSON.string(dict, "error") ?? ""
        }
        if CapJSON.bool(dict, "verified") == true,
           let value = CapJSON.bool(dict, "isSupervised") {
            isSupervised = value
            errorText = nil
        } else {
            await readState()
        }
    }

    private func call(_ capability: String, _ args: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (_, json) = AirliftPocLog.callRaw(capability, args)
                continuation.resume(returning: json)
            }
        }
    }
}

// MARK: - 主题（密码键盘）

/// 锁屏密码键盘主题：选 `.passthm` -> 预览 12 键 -> 一次批量写进 TelephonyUI 缓存.
///
/// 移植自 Mak5er/AirCard 的「Passcode Themes」. 机制与前提见 `PasscodeTheme` 的头注释.
private struct AirliftThemeTab: View {
    let module: EscapeModule

    @State private var theme: PasscodeTheme.Theme?
    @State private var importing = false
    @State private var importingPoster = false
    @State private var working = false
    @State private var steps: [String] = []
    @State private var errorText: String?
    @State private var okText: String?
    @State private var targetVersion = 10

    private var targetDir: String {
        "/var/mobile/Library/Caches/TelephonyUI-\(targetVersion)"
    }

    var body: some View {
        Page {
            HeroCard(icon: "keyboard.fill",
                     title: "密码键盘主题",
                     subtitle: "把 .passthm 的按键图写进系统的 TelephonyUI 缓存",
                     tint: .pink,
                     pill: (theme == nil ? "未选择" : "\(theme!.keys.count) 个按键", .pink))

            CardBox(title: "前提（先说清楚）", icon: "info.circle") {
                Text("需要 TelephonyUI-8 / 9 / 10 里至少有一个**已经存在** —— "
                     + "airlift 在 Media 之外建不了目录，目录不存在时批量写会报 0/N.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CardBox(title: "主题包", icon: "doc.zipper") {
                CardButton(title: "选择 .passthm 文件", icon: "square.and.arrow.down") {
                    importing = true
                }
                CardButton(title: "从一张壁纸切出 12 个按键", icon: "photo") {
                    importingPoster = true
                }
                if let theme {
                    KV(label: "名称", value: theme.name)
                    KV(label: "按键数", value: "\(theme.keys.count)")
                    Picker("目标版本", selection: $targetVersion) {
                        Text("TelephonyUI-10").tag(10)
                        Text("TelephonyUI-9").tag(9)
                        Text("TelephonyUI-8").tag(8)
                    }
                    .pickerStyle(.segmented)
                    Text(targetDir)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }

            if let theme {
                CardBox(title: "预览", icon: "keyboard") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                             count: 3),
                              spacing: 8) {
                        ForEach(PasscodeTheme.keypadOrder, id: \.self) { digit in
                            keyTile(digit: digit, theme: theme)
                        }
                    }
                }

                CardBox(title: "动作", icon: "bolt") {
                    CardButton(title: "应用到设备", icon: "arrow.up.doc",
                               busy: working) {
                        Task { await apply(theme) }
                    }
                    CardButton(title: "导出为 .passthm", icon: "square.and.arrow.up") {
                        exportTheme(theme)
                    }
                    Text("批量写：N 个文件只走 1 趟 airlift.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }

            if let okText { BannerView(kind: .ok, text: okText) }
            if let errorText { BannerView(kind: .error, text: errorText) }
            CompactStepsView(steps: steps)
        }
        .documentPicker(isPresented: $importing, allowedTypes: [.item]) { urls in
            Task { await loadTheme(urls.first) }
        }
        .documentPicker(isPresented: $importingPoster, allowedTypes: [.image]) { urls in
            Task { await slicePoster(urls.first) }
        }
    }

    /// 一个键位的小预览（优先取「无副文本」那张，找不到就取该键位的第一张）.
    @ViewBuilder
    private func keyTile(digit: String, theme: PasscodeTheme.Theme) -> some View {
        let candidates = theme.keys.filter { $0.digit == digit }
        let key = candidates.first(where: { $0.subtext.isEmpty }) ?? candidates.first
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: 54)
                if let key, let image = UIImage(data: key.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 54)
                } else {
                    Text(digit).font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Text(digit).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func loadTheme(_ url: URL?) async {
        guard let url else { return }
        errorText = nil
        okText = nil
        do {
            let loaded = try PasscodeTheme.load(url: url)
            theme = loaded
            targetVersion = loaded.guessedVersion
            okText = "已载入 \(loaded.keys.count) 个按键"
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func slicePoster(_ url: URL?) async {
        guard let url, let image = UIImage(contentsOfFile: url.path) else {
            errorText = "读不到所选图片"
            return
        }
        let keys = PasscodeTheme.slice(poster: image)
        guard !keys.isEmpty else {
            errorText = "切片失败（图片可能太小）"
            return
        }
        theme = PasscodeTheme.Theme(name: url.deletingPathExtension().lastPathComponent,
                                    keys: keys,
                                    guessedVersion: targetVersion)
        errorText = nil
        okText = "已从壁纸切出 \(keys.count) 个按键"
    }

    private func exportTheme(_ theme: PasscodeTheme.Theme) {
        do {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Themes", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(theme.name).passthm")
            try PasscodeTheme.export(theme, to: url)
            okText = "已导出到沙盒 Documents/Themes/\(theme.name).passthm"
            errorText = nil
        } catch {
            errorText = "导出失败：\(error.localizedDescription)"
        }
    }

    private func apply(_ theme: PasscodeTheme.Theme) async {
        working = true
        steps = []
        errorText = nil
        okText = nil
        defer { working = false }

        let files = theme.keys.map { key -> [String: Any] in
            ["name": key.fileName, "data": key.data.base64EncodedString()]
        }
        let json = await call("airlift.writeMany", CapJSON.json([
            "dir": targetDir,
            "files": files,
            "encoding": "base64",
        ]))
        let dict = CapJSON.dict(json)
        steps = CapJSON.strings(dict, "steps")
        if CapJSON.bool(dict, "ok") == true {
            okText = "已写入 \(theme.keys.count) 个按键到 \(targetDir)"
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
        }
    }

    private func call(_ capability: String, _ args: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (_, json) = AirliftPocLog.callRaw(capability, args)
                continuation.resume(returning: json)
            }
        }
    }
}

// MARK: - 日志

private struct AirliftLogTab: View {
    @ObservedObject private var memory = AirliftPocLog.shared

    @State private var entries: [FileEntry] = []
    @State private var loading = false

    struct FileEntry: Identifiable {
        let id = UUID()
        let head: String
        let ok: Bool
        let args: String
        let ret: String
    }

    var body: some View {
        Page {
            HeroCard(icon: "text.alignleft",
                     title: "日志",
                     subtitle: "宿主能力调用的原始 JSON 往来",
                     tint: .blue,
                     pill: ("\(entries.count) 条", .blue))

            CardBox(title: "操作", icon: "wrench") {
                CardButton(title: loading ? "读取中…" : "刷新", icon: "arrow.clockwise",
                           busy: loading) {
                    Task { await reload() }
                }
                CardButton(title: "清空日志", icon: "trash", kind: .danger) {
                    clearAll()
                }
                Text("日志落在 App 沙盒的 CapabilityLog/run.log，重启 App 不会丢，"
                     + "SSH 的 cap 调用也在里面.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            if entries.isEmpty {
                CardBox {
                    Text("还没有调用记录. 在任意 tab 里操作一次就会出现.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }

            ForEach(entries) { entry in
                CardBox {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("入参").font(.system(size: 11)).foregroundColor(.secondary)
                            Text(entry.args)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Text("返回").font(.system(size: 11)).foregroundColor(.secondary)
                            Text(entry.ret)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entry.ok ? Color.green : Color.red)
                                .frame(width: 7, height: 7)
                            Text(entry.head)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .task { await reload() }
    }

    /// 读持久化日志的末尾. 内存里那份随 App 重启清空，而且 SSH 的 cap 调用不经过它，
    /// 所以主来源必须是文件.
    private func reload() async {
        loading = true
        defer { loading = false }
        let url = HostCapabilityService.callLogURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            entries = []
            return
        }
        var out: [FileEntry] = []
        var head: String?
        var args = ""
        var ret = ""
        var ok = true
        func flush() {
            guard let h = head else { return }
            out.append(FileEntry(head: h, ok: ok, args: args, ret: ret))
            head = nil; args = ""; ret = ""; ok = true
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("[") {
                flush()
                head = line
                ok = line.contains("] OK")
            } else if line.hasPrefix("  args:") {
                args = String(line.dropFirst("  args:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("  ret :") {
                ret = String(line.dropFirst("  ret :".count)).trimmingCharacters(in: .whitespaces)
            } else if head != nil {
                ret += "\n" + line
            }
        }
        flush()
        entries = Array(out.suffix(60).reversed())
    }

    private func clearAll() {
        try? FileManager.default.removeItem(at: HostCapabilityService.callLogURL)
        memory.clear()
        entries = []
    }
}
