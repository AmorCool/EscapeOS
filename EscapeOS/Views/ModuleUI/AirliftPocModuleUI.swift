//
//  AirliftPocModuleUI.swift
//  EscapeSpace
//
//  v0.3.481：airlift-poc 模块的原生界面（概览 / 监督模式 / 日志）.
//
//  ## 这个模块为什么这么写
//  它是**第一个**用 `escape.host.v1` 的模块。在此之前，任何需要「沙盒外读写 /
//  改系统设置」的模块都得自己把整套漏洞利用重写一遍 —— airlift-poc 刻意**不**那么做：
//  它只声明 `requires`，然后调宿主能力（`HostCapabilityService.call`）.
//  好处是将来漏洞链被替换（bad_query → airlift → 下一个），本文件**一行都不用改**.
//
//  ## 为什么这里直接调 Swift 而不用 C ABI
//  本界面是**编译进宿主的 Swift 代码**，所以直接调 `HostCapabilityService` 即可.
//  `escape_module_init` + `EscapeHostAPI` 函数表那条路是给**外部 dylib 模块**
//  （C / Go 写的）用的 —— 两条路最终都汇到同一个 `call` 分发器.
//
//  ## 唯一功能：启用监督模式
//  写 `CloudConfigurationDetails.plist` 的 `IsSupervised`.
//  为什么这件事现在才做得成：现有实现靠 `escape.consume(path: configProfiles,
//  isGroup: true)` 拿 bad_query 沙盒扩展，而 iOS 26.5/26.6 对
//  `configurationprofiles` SystemGroup **拒绝签发沙盒扩展** ⇒ 写不进去.
//  airlift 能写任意单个文件 ⇒ 正好补这个洞.
//

import SwiftUI

// MARK: - 调用记录器

/// 宿主能力调用的统一记录器（日志 tab 与各 tab 共用）.
///
/// 记的是**原始 JSON**（不美化、不截断到看不出问题），因为它的用途是排障 ——
/// airlift 一次十几秒、失败可能断在六个不同环节，只有原文能定位.
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

    /// 单条记录里 JSON 原文的保留上限（超出标注「已截断」）——
    /// 不是怕大，是怕一条几 MB 的记录把列表渲染拖死.
    private static let maxTextLength = 4000

    private init() {}

    func record(capability: String, args: String, result: String, ok: Bool) {
        entries.insert(Entry(time: Date(),
                             capability: capability,
                             args: Self.clip(args),
                             result: Self.clip(result),
                             ok: ok),
                       at: 0)
        // 只留最近 200 条：这是内存里的排障窗口，不是持久日志
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }

    func clear() { entries.removeAll() }

    private static func clip(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        return String(text.prefix(maxTextLength)) + "\n…（已截断，原文 \(text.count) 字符）"
    }

    /// 统一的调用入口：调宿主能力并自动记一条日志.
    ///
    /// ⚠️ **同步阻塞**：沙盒外操作走 airlift，一次 10~20 秒. 调用方必须在后台线程调，
    /// 否则卡界面.
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

// MARK: - JSON 读取小工具

/// 从能力返回值里安全取值.
///
/// 刻意不用 Codable 模型：宿主能力的返回结构会随版本加字段，用字典读能**向前兼容**，
/// 而且解析失败时可以原样把文本交给 UI（排障时原文比「解析失败」有用得多）.
private enum CapJSON {
    static func dict(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func bool(_ dict: [String: Any]?, _ key: String) -> Bool? {
        dict?[key] as? Bool
    }

    static func string(_ dict: [String: Any]?, _ key: String) -> String? {
        dict?[key] as? String
    }

    static func int(_ dict: [String: Any]?, _ key: String) -> Int? {
        dict?[key] as? Int
    }

    static func strings(_ dict: [String: Any]?, _ key: String) -> [String] {
        dict?[key] as? [String] ?? []
    }
}

// MARK: - 注册入口

/// 把 airlift-poc 的原生界面注册进宿主.
/// 调用点：`registerBuiltinModuleUIs()`（`EscapeSpaceApp.init()` 里触发）.
@MainActor
func registerAirliftPocModuleUI() {
    ModuleUIRegistry.shared.register("airlift-poc") { module in
        [
            ModuleUITab(id: "overview",
                        title: "概览",
                        systemImage: "gauge.with.dots.needle.33percent") { m in
                AirliftOverviewTab(module: m)
            },
            ModuleUITab(id: "supervised",
                        title: "监督模式",
                        systemImage: "lock.shield") { m in
                AirliftSupervisedTab(module: m)
            },
            ModuleUITab(id: "log",
                        title: "日志",
                        systemImage: "text.alignleft") { m in
                AirliftLogTab()
            },
        ]
    }
}

// MARK: - 概览

/// 概览：宿主版本、模块可用性、airlift 状态、能力清单.
private struct AirliftOverviewTab: View {
    let module: EscapeModule

    @State private var hostVersion = "查询中…"
    @State private var hostBuild = ""
    @State private var airliftAvailable: Bool?
    @State private var supportedCapabilities: [String] = []
    @State private var loading = false

    var body: some View {
        Form {
            Section("模块") {
                LabeledContent("名称", value: module.name)
                LabeledContent("版本", value: "v\(module.version)")
                availabilityRow
            }

            Section("宿主") {
                LabeledContent("版本", value: hostBuild.isEmpty ? hostVersion : "\(hostVersion) (\(hostBuild))")
                LabeledContent("airlift 漏洞利用") {
                    if let airliftAvailable {
                        Text(airliftAvailable ? "可用" : "不可用")
                            .foregroundColor(airliftAvailable ? .green : .orange)
                    } else {
                        Text("查询中…").foregroundColor(.secondary)
                    }
                }
            }

            Section("本机支持的能力") {
                if supportedCapabilities.isEmpty {
                    Text(loading ? "查询中…" : "未取到能力清单")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(declaredCapabilities, id: \.self) { cap in
                        HStack {
                            Image(systemName: supportedCapabilities.contains(cap)
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(supportedCapabilities.contains(cap) ? .green : .red)
                            Text(cap).font(.callout)
                            Spacer()
                            if !supportedCapabilities.contains(cap) {
                                Text("缺失").font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                }
            }

            Section {
                Text("本模块通过宿主能力接口工作，不自己实现漏洞利用。"
                     + "沙盒外操作依赖 airlift，而 airlift 只能读写**单个文件**、"
                     + "无法枚举目录，所以「列目录」这类能力只支持 App 沙盒内路径。"
                     + "监督模式需要宿主 v0.3.481+。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    if loading {
                        HStack { ProgressView(); Text("查询中…") }
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(loading)
            }
        }
        .task { await refresh() }
    }

    /// 模块清单里声明的能力（module.json 的 requires）.
    /// 用它而不是把 `capabilityList` 全列出来 —— 用户关心的是「我这个模块要的齐不齐」.
    private var declaredCapabilities: [String] {
        module.requires ?? []
    }

    private var availabilityRow: some View {
        // blockingIssues 里每条已经是完整句子（「缺少宿主能力：…」/「需要宿主 v…，当前 v…」），
        // 所以这里不再自己加前缀，否则会重复成「缺少宿主能力：缺少宿主能力：fs.read」.
        Group {
            if module.blockingIssues.isEmpty {
                Label("可用", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(module.blockingIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }

        let versionJSON = await call("host.version")
        let capabilitiesJSON = await call("host.capabilities")
        let exploitJSON = await call("exploit.status")

        let versionDict = CapJSON.dict(versionJSON)
        hostVersion = CapJSON.string(versionDict, "version") ?? "未知"
        hostBuild = CapJSON.string(versionDict, "build") ?? ""

        let capsDict = CapJSON.dict(capabilitiesJSON)
        supportedCapabilities = CapJSON.strings(capsDict, "list")

        airliftAvailable = CapJSON.bool(CapJSON.dict(exploitJSON), "airlift")
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

// MARK: - 监督模式

/// 监督模式：读当前状态 → 改 `IsSupervised` → 写回 → 读回校验.
private struct AirliftSupervisedTab: View {
    let module: EscapeModule

    @State private var isSupervised: Bool?
    @State private var plistPath = ""
    @State private var organizationName = ""
    @State private var loading = false
    @State private var running = false
    @State private var confirming = false
    @State private var steps: [String] = []
    @State private var errorText: String?
    @State private var lastBackup: String?

    var body: some View {
        Form {
            Section("当前状态") {
                HStack {
                    Image(systemName: isSupervised == true
                          ? "lock.shield.fill" : "lock.open")
                        .font(.title2)
                        .foregroundColor(isSupervised == true ? .green : .secondary)
                    Text(statusText)
                        .font(.headline)
                    Spacer()
                    if loading { ProgressView() }
                }
                if !plistPath.isEmpty {
                    Text(plistPath)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Button("重新读取") { Task { await readState() } }
                    .disabled(loading || running)
            } footer: {
                Text("读取走 airlift 漏洞利用（沙盒外），单次约 10~20 秒；"
                     + "airlift 的「读」是移动不是拷贝，所以读完会立刻把原文件写回原位，"
                     + "整体约需 20~40 秒。")
            }

            Section("组织名称（可选）") {
                TextField("留空则不写 OrganizationName", text: $organizationName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Button {
                    confirming = true
                } label: {
                    if running {
                        HStack { ProgressView(); Text("执行中（airlift 约需 40~80 秒）…") }
                    } else {
                        Label(isSupervised == true ? "关闭监督模式" : "启用监督模式",
                              systemImage: isSupervised == true
                              ? "lock.open.fill" : "lock.shield.fill")
                    }
                }
                .disabled(running || loading || isSupervised == nil || !module.isUsable)
            } footer: {
                if !module.isUsable {
                    Text("模块当前不可用，无法执行。")
                } else {
                    Text("全程走 airlift：读 → 改 → 写 → 读回校验，共 4 次操作，"
                         + "约需 40~80 秒。原文件会自动备份到 App 沙盒。")
                }
            }

            if !steps.isEmpty {
                Section("执行步骤") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: stepIcon(step))
                                .font(.caption)
                                .foregroundColor(stepColor(step))
                            Text(step).font(.caption)
                        }
                    }
                }
            }

            if let errorText {
                Section("错误原文") {
                    Text(errorText)
                        .font(.caption)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
            }

            if let lastBackup {
                Section("原文件备份") {
                    Text(lastBackup)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .task { await readState() }
        .confirmationDialog(
            isSupervised == true ? "确认关闭监督模式？" : "确认启用监督模式？",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(isSupervised == true ? "关闭监督模式" : "启用监督模式",
                   role: .destructive) {
                Task { await apply(!(isSupervised ?? false)) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将修改系统配置文件 CloudConfigurationDetails.plist 的 IsSupervised。"
                 + "这是不可逆的调试操作，可能影响系统行为，请确认已了解风险。"
                 + "原文件会自动备份到 App 沙盒。")
        }
    }

    private var statusText: String {
        guard let isSupervised else { return "读取中（airlift 约需 20~40 秒）…" }
        return isSupervised ? "已开启监督模式" : "未开启监督模式"
    }

    private func stepIcon(_ step: String) -> String {
        if step.hasPrefix("⚠️") { return "exclamationmark.triangle.fill" }
        if step.hasPrefix("write:") { return "square.and.pencil" }
        return "checkmark.circle.fill"
    }

    private func stepColor(_ step: String) -> Color {
        if step.hasPrefix("⚠️") { return .orange }
        return .secondary
    }

    /// 读当前状态（走 `sys.supervised.get`，非破坏性）.
    private func readState() async {
        loading = true
        defer { loading = false }
        let json = await call("sys.supervised.get", "{}")
        let dict = CapJSON.dict(json)
        if let value = CapJSON.bool(dict, "isSupervised") {
            isSupervised = value
            plistPath = CapJSON.string(dict, "path") ?? ""
            if let org = CapJSON.string(dict, "organizationName"), !org.isEmpty {
                organizationName = org
            }
            errorText = nil
        } else {
            isSupervised = nil
            errorText = CapJSON.string(dict, "error") ?? "读取失败，返回内容：\(json)"
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
        let argsJSON = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"enabled\":\(enabled)}"

        let json = await call("sys.supervised.set", argsJSON)
        let dict = CapJSON.dict(json)
        steps = CapJSON.strings(dict, "steps")
        lastBackup = CapJSON.string(dict, "backup")
        if CapJSON.bool(dict, "ok") != true {
            errorText = CapJSON.string(dict, "error") ?? "执行失败，返回内容：\(json)"
        }

        // **不轻信写入返回值**：无论成败都重新读一次真实状态 ——
        // 这是唯一能证明「系统里到底是什么」的判据.
        await readState()
    }

    /// 同步宿主能力放后台线程（airlift 一次十几秒）.
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

/// 日志：宿主能力调用的原始 JSON 往来（排障用）.
private struct AirliftLogTab: View {
    @ObservedObject private var log = AirliftPocLog.shared

    var body: some View {
        Group {
            if log.entries.isEmpty {
                ContentUnavailableView("还没有调用记录",
                                       systemImage: "text.alignleft",
                                       description: Text("在「概览」或「监督模式」里操作后会出现在这里。"))
            } else {
                List {
                    // 「清空」放在列表首行而不是 `.toolbar` —— 模块二级界面**没有**
                    // NavigationStack（外壳刻意不套，避免和常驻顶栏叠成双层栏），
                    // 没有导航栏可挂，toolbar 里的按钮不会渲染出来.
                    Section {
                        Button(role: .destructive) {
                            log.clear()
                        } label: {
                            Label("清空记录（\(log.entries.count) 条）", systemImage: "trash")
                        }
                    }
                    ForEach(log.entries) { entry in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("入参").font(.caption).foregroundColor(.secondary)
                                Text(entry.args)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                Text("返回").font(.caption).foregroundColor(.secondary)
                                Text(entry.result)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(entry.ok ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.capability).font(.callout)
                                    Text(entry.time.formatted(date: .omitted, time: .standard))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
