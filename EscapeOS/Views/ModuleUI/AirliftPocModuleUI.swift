//
//  AirliftPocModuleUI.swift
//  EscapeSpace
//
//  airlift-poc 模块的原生界面.
//
//  ## 视觉一律跟随主程序（用户要求：不要自己乱改 UI）
//  复用 `EscapeOS/Views/DesignSystem.swift` 那套：
//  · `AppTheme.accent`（系统蓝）、`AppRowIcon`、`SizePill`
//  · `List` + `.listStyle(.insetGrouped)`、`Section { } header/footer`、`LabeledContent`
//  · 强调动作用 `.buttonStyle(.borderedProminent)`
//  外壳 `ModuleHostShell` 已经给了顶栏标题与底部 tab 栏，所以这里**不套 NavigationStack、
//  不设 navigationTitle**（套了会变成双层栏）.
//
//  ## 三条硬规则（用户明确要求）
//  1. 不用黄色感叹号 —— 不用 ⚠️，也不用 exclamationmark.triangle
//  2. 代码注释是给开发者看的，界面上一个字都不显示（`StepText.clean` 负责清）
//  3. 句号一律英文 `.`，给用户看的描述要精简
//
//  ## 这个模块为什么这么写
//  它只声明 requires，然后调宿主能力（`HostCapabilityService.call`）. 将来漏洞链被替换
//  （airlift -> 下一个），本文件一行都不用改.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 步骤文本清洗

/// 把能力返回的「步骤」原文清成**给人看的短句**.
///
/// 能力返回的步骤里带大量给开发者的解释：`⚠️`、`★`、markdown 的 `**` 与反引号、
/// 以及括号里那串「为什么 / 判据 / 边界」. 那些在**日志**里有用，在**界面**上是噪音.
/// 这里只留「做了什么、成没成」；原文照样能在展开后的「全部行」和日志里看到.
private enum StepText {
    static func clean(_ raw: String) -> String {
        var text = raw
        for junk in ["⚠️", "\u{FE0F}", "★", "**", "`", "❌", "✅"] {
            text = text.replacingOccurrences(of: junk, with: "")
        }
        for pair in [("（", "）"), ("(", ")")] {
            while let open = text.firstIndex(of: Character(pair.0)),
                  let close = text[text.index(after: open)...].firstIndex(of: Character(pair.1)) {
                text.removeSubrange(open...close)
            }
        }
        text = text.split(separator: " ").joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 步骤列表：默认只显示关键行，技术判据折起来.
///
/// 刻意做成 `Section` 内的普通行（不自己画卡片）—— 与主程序的列表风格一致.
private struct CompactStepsSection: View {
    let steps: [String]
    var title: String = "执行步骤"
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
            Section {
                ForEach(Array((expanded ? steps : keySteps).enumerated()), id: \.offset) { _, step in
                    StepRow(text: step, raw: expanded)
                }
                if keySteps.count < steps.count {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        Label(expanded ? "收起技术细节" : "显示全部 \(steps.count) 行",
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                }
            } header: {
                Text(title)
            }
        }
    }
}

/// 单条步骤：小圆点 + 文本.
private struct StepRow: View {
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
                .font(.caption)
                .foregroundColor(isWarn ? .orange : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 调用记录器

/// 宿主能力调用的内存记录（日志 tab 的兜底；主来源是 CapabilityLog/run.log）.
@MainActor
private final class AirliftPocLog: ObservableObject {
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
}

/// 统一的异步调用（宿主能力是同步阻塞的，放后台线程）.
private func airliftCall(_ capability: String, _ args: String) async -> String {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let (_, json) = AirliftPocLog.callRaw(capability, args)
            continuation.resume(returning: json)
        }
    }
}

/// 结果 / 错误行 —— 与主程序一致：列表内一行彩色文字，不自己画横幅.
@ViewBuilder
private func resultRows(ok: String?, error: String?) -> some View {
    if let ok {
        Section {
            Text(ok).font(.caption).foregroundColor(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    if let error {
        Section {
            Text(error).font(.caption).foregroundColor(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("错误")
        }
    }
}

/// 字节数格式化.
private func byteText(_ size: Int) -> String {
    if size >= 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576) }
    if size >= 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
    return "\(size) B"
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
            ModuleUITab(id: "theme", title: "主题",
                        systemImage: "keyboard") { m in
                AirliftThemeTab(module: m)
            },
            ModuleUITab(id: "supervised", title: "监督",
                        systemImage: "lock.shield") { m in
                AirliftSupervisedTab(module: m)
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
        List {
            Section {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "bolt.horizontal.circle.fill",
                               tint: .purple, symbolSize: 20, frameSize: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.name).font(.subheadline.weight(.semibold))
                        Text("v\(module.version)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    SizePill(text: module.isUsable ? "可用" : "不可用",
                             tint: module.isUsable ? .green : .orange)
                }
            }

            if !module.blockingIssues.isEmpty {
                Section {
                    ForEach(module.blockingIssues, id: \.self) { issue in
                        Text(issue).font(.caption).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("为什么不可用")
                }
            }

            Section {
                LabeledContent("版本",
                               value: hostBuild.isEmpty ? hostVersion : "\(hostVersion) (\(hostBuild))")
                LabeledContent("airlift（本模块读写）") {
                    Text(airliftRunnable == nil ? "查询中…" : (airliftRunnable! ? "可用" : "不可用"))
                        .foregroundColor(airliftRunnable == nil ? .secondary
                                         : (airliftRunnable! ? .green : .orange))
                }
                LabeledContent("「漏洞利用」里的 airlift") {
                    Text(airliftEnabled == nil ? "查询中…" : (airliftEnabled! ? "已启用" : "未启用"))
                        .foregroundColor(airliftEnabled == nil ? .secondary
                                         : (airliftEnabled! ? .green : .orange))
                }
            } header: {
                Text("宿主")
            } footer: {
                if !exploitNote.isEmpty { Text(exploitNote) }
            }

            Section {
                if supportedCapabilities.isEmpty {
                    Text(loading ? "查询中…" : "未取到能力清单").foregroundColor(.secondary)
                } else {
                    ForEach(module.requires ?? [], id: \.self) { cap in
                        HStack(spacing: 8) {
                            Image(systemName: supportedCapabilities.contains(cap)
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(supportedCapabilities.contains(cap) ? .green : .red)
                            Text(cap).font(.system(.caption, design: .monospaced))
                            Spacer()
                            if !supportedCapabilities.contains(cap) {
                                Text("缺失").font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                }
            } header: {
                Text("本模块声明的能力")
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    if loading {
                        HStack { ProgressView().controlSize(.small); Text("查询中…") }
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(loading)
            }
        }
        .listStyle(.insetGrouped)
        .task { await refresh() }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        let versionDict = CapJSON.dict(await airliftCall("host.version", "{}"))
        hostVersion = CapJSON.string(versionDict, "version") ?? "未知"
        hostBuild = CapJSON.string(versionDict, "build") ?? ""

        supportedCapabilities = CapJSON.strings(
            CapJSON.dict(await airliftCall("host.capabilities", "{}")), "list")

        let exploitDict = CapJSON.dict(await airliftCall("exploit.status", "{}"))
        airliftRunnable = CapJSON.bool(exploitDict, "airliftRunnable")
        airliftEnabled = CapJSON.bool(exploitDict, "airliftEnabled")
        exploitNote = CapJSON.string(exploitDict, "note") ?? ""
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
    @State private var previewEntry: AfcEntry?
    @State private var previewText = ""
    @State private var previewLoading = false
    @State private var deleteEntry: AfcEntry?
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
        List {
            Section {
                Picker("根", selection: $root) {
                    Text("/var/mobile/Media").tag("media")
                    Text("CrashReporter").tag("crash")
                }
                .pickerStyle(.segmented)
                .onChange(of: root) { _ in
                    path = "/"
                    Task { await load() }
                }

                HStack(spacing: 8) {
                    AppRowIcon(systemName: "externaldrive.fill", symbolSize: 13, frameSize: 24)
                    Text(path == "/" ? rootDisplay : path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }

                Button {
                    Task { await goUp() }
                } label: {
                    Label("上一级", systemImage: "arrow.up")
                }
                .disabled(path == "/" || loading)

                Button {
                    Task { await load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            } header: {
                Text("位置")
            } footer: {
                Text("本页走 AFC（不是 airlift），在这两个根上是完整文件管理器.")
            }

            if let errorText {
                Section("错误") {
                    Text(errorText).font(.caption).foregroundColor(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if entries.isEmpty && !loading {
                    Text("目录为空").foregroundColor(.secondary)
                }
                ForEach(entries) { entry in
                    Button {
                        if entry.isDir {
                            Task { await enter(entry) }
                        } else {
                            Task { await preview(entry) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                                .foregroundColor(entry.isDir ? AppTheme.accent : .secondary)
                            Text(entry.name)
                                .font(.callout)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            if entry.isDir {
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundColor(.secondary)
                            } else {
                                SizePill(text: byteText(entry.size), tint: .secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteEntry = entry
                            confirmingDelete = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("内容（\(entries.count) 项）")
            }

            Section {
                HStack(spacing: 8) {
                    TextField("新目录名", text: $newFolderName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("创建") { Task { await makeFolder() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                        .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("新建目录")
            }

            Section {
                TextField("相对当前根的路径，可含 ..", text: $statPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Button("查一下") { Task { await doStat() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(AppTheme.accent)
                if !statResult.isEmpty {
                    Text(statResult).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("探测任意路径")
            } footer: {
                Text("Media 之外读 / 写 / 列都会被沙盒拒，但 stat 能过 —— 一次 AFC 往返、几十毫秒.")
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $previewEntry) { entry in
            NavigationStack {
                ScrollView {
                    Text(previewLoading ? "读取中…" : previewText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppTheme.pageInset)
                        .textSelection(.enabled)
                }
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .confirmationDialog("删除 \(deleteEntry?.name ?? "")？",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteSelected() } }
            Button("取消", role: .cancel) {}
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let json = await airliftCall("afc.list", CapJSON.json(["root": root, "path": path]))
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
        }.sorted { lhs, rhs in
            if lhs.isDir != rhs.isDir { return lhs.isDir }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
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
        previewEntry = entry
        previewLoading = true
        previewText = ""
        defer { previewLoading = false }
        let json = await airliftCall("afc.read",
                                     CapJSON.json(["root": root,
                                                   "path": entry.path,
                                                   "encoding": "utf8"]))
        let dict = CapJSON.dict(json)
        previewText = CapJSON.bool(dict, "ok") == true
            ? (CapJSON.string(dict, "data") ?? "")
            : (CapJSON.string(dict, "error") ?? json)
    }

    private func deleteSelected() async {
        guard let entry = deleteEntry else { return }
        let json = await airliftCall("afc.delete",
                                     CapJSON.json(["root": root, "path": entry.path]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") != true {
            errorText = CapJSON.string(dict, "error") ?? json
        }
        deleteEntry = nil
        await load()
    }

    private func makeFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let base = path == "/" ? "" : path
        let json = await airliftCall("afc.mkdir",
                                     CapJSON.json(["root": root, "path": "\(base)/\(name)"]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") == true {
            newFolderName = ""
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
        }
        await load()
    }

    private func doStat() async {
        let value = statPath.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        let json = await airliftCall("afc.stat", CapJSON.json(["root": root, "path": value]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "exists") == true {
            statResult = "存在 · \(CapJSON.string(dict, "ifmt") ?? "?")"
                + " · \(byteText(CapJSON.int(dict, "size") ?? 0))"
        } else {
            statResult = CapJSON.string(dict, "describe")
                ?? CapJSON.string(dict, "error") ?? "取不到"
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
        List {
            Section {
                TextField("/var/mobile/... 绝对路径", text: $target)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                Toggle("目标是目录（写到它下面）", isOn: $targetIsDirectory)
                if targetIsDirectory {
                    TextField("文件名（留空 = 用源文件名）", text: $leafName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("目标")
            } footer: {
                Text(targetIsDirectory ? "落点 = 目标目录 / 文件名" : "落点 = 上面填的这个路径本身")
            }

            Section {
                if airFiles.isEmpty {
                    Text("AIR 里还没有文件. 点下面导入，或先把目标读回来.")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(airFiles) { file in
                    Button {
                        selectedAirName = file.name
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedAirName == file.name
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(selectedAirName == file.name
                                                 ? AppTheme.accent : .secondary)
                            Text(file.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            SizePill(text: byteText(file.size), tint: .secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await deleteAirFile(file.name) }
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                    }
                }
                Button {
                    importing = true
                } label: {
                    Label("从本机选择文件导入", systemImage: "square.and.arrow.down")
                }
                Button {
                    Task { await pullToAir() }
                } label: {
                    Label("把目标读回来（不改动目标）", systemImage: "arrow.down.doc")
                }
                .disabled(working || target.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("源文件（AIR）")
            }

            Section {
                Toggle("覆盖前先把目标备份到 AIR（.bak）", isOn: $backupFirst)
                Button {
                    confirming = true
                } label: {
                    if working {
                        HStack { ProgressView().controlSize(.small); Text("执行中…") }
                    } else {
                        Label("覆盖目标", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                .disabled(working || selectedAirName == nil
                          || target.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("删除目标文件", systemImage: "trash")
                }
                .disabled(working || target.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("动作")
            } footer: {
                if let selectedAirName {
                    Text("将用 AIR/\(selectedAirName) 覆盖 \(target)")
                } else {
                    Text("先选一个源文件，再填目标路径.")
                }
            }

            resultRows(ok: okText, error: errorText)
            CompactStepsSection(steps: steps)
        }
        .listStyle(.insetGrouped)
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

    private func refreshAirList() async {
        let dict = CapJSON.dict(await airliftCall("airlift.air", CapJSON.json(["op": "list"])))
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
        let dict = CapJSON.dict(await airliftCall("airlift.air",
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
        let dict = CapJSON.dict(await airliftCall("airlift.air", args))
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
        let path = target.trimmingCharacters(in: .whitespaces)
        let json = await airliftCall("airlift.pull", CapJSON.json(["path": path]))
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
        let path = target.trimmingCharacters(in: .whitespaces)
        let json = await airliftCall("airlift.delete", CapJSON.json(["path": path]))
        let dict = CapJSON.dict(json)
        steps = CapJSON.strings(dict, "steps")
        if CapJSON.bool(dict, "ok") == true {
            okText = "已删除 \(path)"
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
        let json = await airliftCall("airlift.overwrite", CapJSON.json(payload))
        let dict = CapJSON.dict(json)
        steps = CapJSON.strings(dict, "steps")
        if CapJSON.bool(dict, "ok") == true {
            okText = "已写入 \(CapJSON.string(dict, "target") ?? "")"
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
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

    private var targetDir: String { "/var/mobile/Library/Caches/TelephonyUI-\(targetVersion)" }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "keyboard.fill", tint: .pink, symbolSize: 20, frameSize: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("密码键盘主题").font(.subheadline.weight(.semibold))
                        Text(theme == nil ? "未选择主题包" : "\(theme!.keys.count) 个按键")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            } footer: {
                Text("需要 TelephonyUI-8 / 9 / 10 里至少有一个已经存在 —— airlift 在 Media 之外建不了目录.")
            }

            Section {
                Button {
                    importing = true
                } label: {
                    Label("选择 .passthm 文件", systemImage: "square.and.arrow.down")
                }
                Button {
                    importingPoster = true
                } label: {
                    Label("从一张壁纸切出 12 个按键", systemImage: "photo")
                }
                if theme != nil {
                    Picker("目标版本", selection: $targetVersion) {
                        Text("TelephonyUI-10").tag(10)
                        Text("TelephonyUI-9").tag(9)
                        Text("TelephonyUI-8").tag(8)
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("主题包")
            } footer: {
                if theme != nil {
                    Text(targetDir).font(.system(.caption2, design: .monospaced))
                }
            }

            if let theme {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                             count: 3),
                              spacing: 8) {
                        ForEach(PasscodeTheme.keypadOrder, id: \.self) { digit in
                            keyTile(digit: digit, theme: theme)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("预览")
                }

                Section {
                    Button {
                        Task { await apply(theme) }
                    } label: {
                        if working {
                            HStack { ProgressView().controlSize(.small); Text("执行中…") }
                        } else {
                            Label("应用到设备", systemImage: "arrow.up.doc")
                        }
                    }
                    .disabled(working)
                    Button {
                        exportTheme(theme)
                    } label: {
                        Label("导出为 .passthm", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("动作")
                } footer: {
                    Text("批量写：N 个文件只走 1 趟 airlift.")
                }
            }

            resultRows(ok: okText, error: errorText)
            CompactStepsSection(steps: steps)
        }
        .listStyle(.insetGrouped)
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
                    Text(digit).font(.title3).foregroundColor(.secondary)
                }
            }
            Text(digit).font(.caption2).foregroundColor(.secondary)
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
        let json = await airliftCall("airlift.writeMany", CapJSON.json([
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
        List {
            Section {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: isSupervised == true ? "lock.shield.fill" : "lock.open",
                               tint: isSupervised == true ? .green : .secondary,
                               symbolSize: 20, frameSize: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("监督模式").font(.subheadline.weight(.semibold))
                        Text(isSupervised == nil ? "读取中…" : (isSupervised! ? "已开启" : "未开启"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    SizePill(text: isSupervised == nil ? "…" : (isSupervised! ? "开" : "关"),
                             tint: isSupervised == true ? .green : .secondary)
                }
            }

            Section {
                Text("这个目标做不到. CloudConfigurationDetails.plist 在 SystemGroup 容器里，"
                     + "沙盒只允许读 / 移出、拒绝创建 / 写入 —— 读得到 412 字节，"
                     + "但覆盖后读回一点没变，连在同一个目录里新建一个文件都建不出来.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("结论先说")
            } footer: {
                Text("对照：/var/mobile/Library/** 下的文件可以正常覆盖.")
            }

            Section {
                LabeledContent("IsSupervised") {
                    Text(isSupervised == nil ? "读取中…" : (isSupervised! ? "true" : "false"))
                        .foregroundColor(isSupervised == true ? .green : .secondary)
                }
                TextField("组织名称（可选）", text: $organizationName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await readState() }
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            } header: {
                Text("当前状态")
            }

            Section {
                Button {
                    confirming = true
                } label: {
                    if running {
                        HStack { ProgressView().controlSize(.small); Text("执行中…") }
                    } else {
                        Label(isSupervised == true ? "关闭监督模式" : "启用监督模式",
                              systemImage: isSupervised == true ? "lock.open.fill" : "lock.shield.fill")
                    }
                }
                .disabled(isSupervised == nil || running)
            } header: {
                Text("操作")
            } footer: {
                Text("流程：读回原文件 -> 把原字节写回原位 -> 覆盖新内容 -> 读回校验. 约 50~100 秒.")
            }

            resultRows(ok: nil, error: errorText)
            CompactStepsSection(steps: steps)
        }
        .listStyle(.insetGrouped)
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
        let dict = CapJSON.dict(await airliftCall("sys.supervised.get", "{}"))
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
        let dict = CapJSON.dict(await airliftCall("sys.supervised.set", CapJSON.json(payload)))
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
        List {
            Section {
                Button {
                    Task { await reload() }
                } label: {
                    Label(loading ? "读取中…" : "刷新", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                Button(role: .destructive) {
                    clearAll()
                } label: {
                    Label("清空日志", systemImage: "trash")
                }
            } footer: {
                Text("日志落在 App 沙盒的 CapabilityLog/run.log，重启 App 不会丢，"
                     + "SSH 的 cap 调用也在里面.")
            }

            if entries.isEmpty {
                Section {
                    Text("还没有调用记录. 在任意 tab 里操作一次就会出现.")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                ForEach(entries) { entry in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("入参").font(.caption).foregroundColor(.secondary)
                            Text(entry.args)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                            Text("返回").font(.caption).foregroundColor(.secondary)
                            Text(entry.ret)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entry.ok ? Color.green : Color.red)
                                .frame(width: 7, height: 7)
                            Text(entry.head)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                }
            } header: {
                Text("最近 \(entries.count) 条")
            }
        }
        .listStyle(.insetGrouped)
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
