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
// `.fileImporter` 的 `allowedContentTypes` 要 UTType，`.item` 来自这个模块
import UniformTypeIdentifiers

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
            ModuleUITab(id: "overwrite",
                        title: "自定义覆盖",
                        systemImage: "square.and.arrow.up.on.square") { m in
                AirliftOverwriteTab(module: m)
            },
            ModuleUITab(id: "files",
                        title: "文件浏览",
                        systemImage: "folder") { m in
                AirliftFilesTab(module: m)
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
    /// airlift 的 poc 接口是否可用（**与设置开关无关** —— 见 HostCapabilityService.exploitStatus 注释）
    @State private var airliftRunnable: Bool?
    /// 「更多 → 漏洞利用」里 airlift 的勾选状态
    @State private var airliftEnabled: Bool?
    @State private var exploitNote = ""
    @State private var supportedCapabilities: [String] = []
    @State private var loading = false

    var body: some View {
        Form {
            Section("模块") {
                LabeledContent("名称", value: module.name)
                LabeledContent("版本", value: "v\(module.version)")
                availabilityRow
            }

            // ⚠️ 这里刻意分两行显示两个**不同**的东西：
            //   · airlift 的 poc 接口能不能用（本模块靠它读写）
            //   · 「更多 → 漏洞利用」里有没有勾选 airlift（影响别的功能和后台自检）
            // 只显示一个必然误导 —— 详见 HostCapabilityService.exploitStatus 的注释.
            Section {
                LabeledContent("版本", value: hostBuild.isEmpty ? hostVersion : "\(hostVersion) (\(hostBuild))")
                LabeledContent("airlift（本模块读写）") {
                    if let airliftRunnable {
                        Text(airliftRunnable ? "可用" : "不可用")
                            .foregroundColor(airliftRunnable ? .green : .orange)
                    } else {
                        Text("查询中…").foregroundColor(.secondary)
                    }
                }
                LabeledContent("「漏洞利用」设置里的 airlift") {
                    if let airliftEnabled {
                        Text(airliftEnabled ? "已启用" : "未启用")
                            .foregroundColor(airliftEnabled ? .green : .orange)
                    } else {
                        Text("查询中…").foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("宿主")
            } footer: {
                if !exploitNote.isEmpty {
                    Text(exploitNote)
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

        let exploitDict = CapJSON.dict(exploitJSON)
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
            // ⚠️ 带 footer 时必须用 `Section { } header: { } footer: { }` 这种形式 ——
            // SwiftUI **没有** `Section("标题") { } footer: { }` 这个重载
            //（v0.3.481 CI 实测：会报 "missing argument label 'content:'" +
            // "cannot convert value of type 'String' to expected argument type '() -> Content'"）.
            Section {
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
            } header: {
                Text("当前状态")
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
                        HStack { ProgressView(); Text("执行中（airlift 约需 50~100 秒）…") }
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
                    Text("全程走 airlift，共 5 次操作，约需 50~100 秒：\n"
                         + "① 读回原文件（读是移动，文件先进 Media）\n"
                         + "② 把原字节**写回原位** —— 「先写入拷贝回来的东西」\n"
                         + "③ 改 IsSupervised → ④ **覆盖**目标文件 —— 「再覆盖目标文件回写」\n"
                         + "⑤ 读回校验（不轻信写入返回值）\n"
                         + "原文件会自动备份到 App 沙盒（AIR/<扁平名>.bak）。")
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
        if step.contains("write:") { return "square.and.pencil" }
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

        // **不轻信写入返回值**：无论成败都要有「系统里到底是什么」的独立判据。
        //
        // ⚠️ 但**不要**在这里无条件再读一次 —— `sys.supervised.set` 在
        // `verify: true`（默认）时**内部已经做过读回校验**（`verified = true`，
        // 返回的 `isSupervised` 就是读回的真实值）。再读一次要多花 2 次 airlift
        // 操作（约 20~40 秒），而设备端 RSD 隧道在连续多次建连后有卡死的先例
        // （真机实测第 6 次 AT 会话卡在 conduit 建连、之后整条队列堵死）。
        // ⇒ 已校验就直接采用读回值；没校验（verify=false）才补读。
        if CapJSON.bool(dict, "verified") == true,
           let value = CapJSON.bool(dict, "isSupervised") {
            isSupervised = value
            plistPath = CapJSON.string(dict, "path") ?? plistPath
            if let org = CapJSON.string(dict, "organizationName"), !org.isEmpty {
                organizationName = org
            }
            errorText = nil
        } else {
            await readState()
        }
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

// MARK: - 自定义覆盖

/// 「自定义覆盖」——把 AIR 里的一个文件覆盖到任意沙盒外路径.
///
/// ## 产品形态参考 lara，但漏洞利用完全不同（别误解）
/// 界面形态参考 `github.com/rooootdev/lara` 的 Custom Overwrite：
/// 「填目标路径 + 选源文件 → 覆盖」。但**机制完全不同**：
/// · lara 走 DarkSword 内核链，在**内核层原地覆盖字节** ⇒ 硬性要求「目标文件 ≥ 源文件」；
/// · 我们走 airlift 的越界写 ⇒ **没有这个限制**，目标可以比源小/大、甚至可以不存在。
///
/// ## 为什么要经过 AIR
/// `/var/mobile/Media/AIR` 是 AFC 的根目录之下，宿主能用**一条 AFC 连接**廉价读写；
/// 而沙盒外的目标只能靠 airlift 搬（一趟 10~20 秒）。所以流程是：
/// **源文件先落进 AIR → 再用 airlift 覆盖目标**。这样源文件的查看/替换/删除都是瞬时的。
private struct AirliftOverwriteTab: View {
    let module: EscapeModule

    @State private var target = ""
    @State private var airFiles: [AirFile] = []
    @State private var selectedAirName: String?
    @State private var backupFirst = true
    @State private var loadingList = false
    @State private var working = false
    @State private var importing = false
    @State private var confirming = false
    @State private var steps: [String] = []
    @State private var errorText: String?
    @State private var okText: String?
    @State private var airDir = ""

    private struct AirFile: Identifiable {
        let name: String
        let size: Int
        var id: String { name }
    }

    var body: some View {
        Form {
            // 同「当前状态」：带 footer 用 header/footer 形式，没有 `Section("标题") {} footer: {}`
            Section {
                TextField("/var/mobile/... 绝对路径", text: $target)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.callout, design: .monospaced))
                Button {
                    Task { await pullToAir() }
                } label: {
                    Label("把目标读到 AIR（读取，不改动目标）", systemImage: "arrow.down.doc")
                }
                .disabled(working || target.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("目标路径")
            } footer: {
                Text("读取会把目标文件拉一份副本到 AIR（原文件读后立刻写回原位，不会被搬走）。")
            }

            Section("源文件（AIR 中转站）") {
                if loadingList {
                    HStack { ProgressView(); Text("读取 AIR 目录…") }
                } else if airFiles.isEmpty {
                    Text("AIR 里还没有文件。点下面「从本机选择文件」导入，或先用上面的「把目标读到 AIR」。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    // 每行是「选择」+「删除」两个**平级**按钮，不用 `ForEach(...).onDelete` ——
                    // onDelete 要求 ForEach 是 List/Form 的直接子视图，而这里它在 if/else 分支里，
                    // 滑动删除不可靠（甚至不出现）。
                    ForEach(airFiles) { file in
                        HStack(spacing: 10) {
                            Button {
                                selectedAirName = file.name
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedAirName == file.name
                                          ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(selectedAirName == file.name ? .accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .lineLimit(2)
                                        Text(byteText(file.size))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task { await deleteAirFile(file.name) }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .disabled(working)
                        }
                    }
                }

                Button {
                    importing = true
                } label: {
                    Label("从本机选择文件导入到 AIR", systemImage: "square.and.arrow.down")
                }
                .disabled(working || importing)

                if !airDir.isEmpty {
                    Text(airDir)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Toggle("覆盖前先把目标备份到 AIR（.bak）", isOn: $backupFirst)

                Button {
                    confirming = true
                } label: {
                    if working {
                        HStack { ProgressView(); Text("执行中（airlift 约需 20~60 秒）…") }
                    } else {
                        Label("覆盖目标", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                .disabled(working || !canOverwrite)
            } footer: {
                if let selectedAirName {
                    Text("将用 AIR/\(selectedAirName) 覆盖 \(target.isEmpty ? "（未填目标路径）" : target)")
                } else {
                    Text("先选一个源文件，再填目标路径。")
                }
            }

            if !steps.isEmpty {
                Section("执行步骤") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: step.hasPrefix("⚠️") || step.hasPrefix("② ⚠️")
                                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(step.contains("⚠️") ? .orange : .secondary)
                            Text(step).font(.caption)
                        }
                    }
                }
            }

            if let okText {
                Section("结果") {
                    Text(okText).font(.callout).foregroundColor(.green)
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
        }
        .task { await refreshAirList() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            Task { await importPicked(result) }
        }
        .confirmationDialog(
            "确认覆盖目标文件？",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("覆盖", role: .destructive) {
                Task { await overwrite() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将用 AIR/\(selectedAirName ?? "?") 的字节覆盖 \(target)。"
                 + (backupFirst ? "覆盖前会先把目标原内容备份到 AIR（.bak）。" : "⚠️ 已关闭备份。")
                 + " 这是不可逆操作，请确认目标路径无误。")
        }
    }

    private var canOverwrite: Bool {
        selectedAirName != nil && !target.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func byteText(_ size: Int) -> String {
        if size >= 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576) }
        if size >= 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return "\(size) B"
    }

    // MARK: 能力调用

    private func call(_ capability: String, _ args: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (_, json) = AirliftPocLog.callRaw(capability, args)
                continuation.resume(returning: json)
            }
        }
    }

    private func refreshAirList() async {
        loadingList = true
        defer { loadingList = false }
        let json = await call("airlift.air", "{\"op\":\"list\"}")
        let dict = CapJSON.dict(json)
        airDir = CapJSON.string(dict, "dir") ?? ""
        let raw = (dict?["entries"] as? [[String: Any]]) ?? []
        airFiles = raw.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let isDir = (item["isDir"] as? Bool) ?? false
            guard !isDir else { return nil }
            return AirFile(name: name, size: (item["size"] as? Int) ?? 0)
        }
        if let selected = selectedAirName, !airFiles.contains(where: { $0.name == selected }) {
            selectedAirName = nil
        }
    }

    private func deleteAirFile(_ name: String) async {
        let args = jsonString(["op": "delete", "name": name])
        let json = await call("airlift.air", args)
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") != true {
            errorText = CapJSON.string(dict, "error") ?? json
        }
        if selectedAirName == name { selectedAirName = nil }
        await refreshAirList()
    }

    private func importPicked(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result {
                errorText = "选择文件失败：\(error.localizedDescription)"
            }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorText = "读不到所选文件：\(url.lastPathComponent)"
            return
        }
        let args = jsonString([
            "op": "write",
            "name": url.lastPathComponent,
            "data": data.base64EncodedString(),
            "encoding": "base64",
        ])
        let json = await call("airlift.air", args)
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") == true {
            okText = "已导入 \(url.lastPathComponent)（\(data.count) 字节）到 AIR"
            errorText = nil
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
        }
        await refreshAirList()
    }

    /// 读取目标到 AIR（不改动目标）
    private func pullToAir() async {
        working = true
        steps = []
        errorText = nil
        okText = nil
        defer { working = false }
        let path = target.trimmingCharacters(in: .whitespaces)
        let json = await call("airlift.pull", jsonString(["path": path]))
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

    private func overwrite() async {
        working = true
        steps = []
        errorText = nil
        okText = nil
        defer { working = false }
        let payload: [String: Any] = [
            "target": target.trimmingCharacters(in: .whitespaces),
            "airName": selectedAirName ?? "",
            "backup": backupFirst,
        ]
        let json = await call("airlift.overwrite", jsonString(payload))
        let dict = CapJSON.dict(json)
        steps = CapJSON.strings(dict, "steps")
        if CapJSON.bool(dict, "ok") == true {
            okText = "已覆盖 \(CapJSON.string(dict, "path") ?? "")"
                + "（\(CapJSON.int(dict, "size") ?? 0) 字节）"
                + "。要确认内容请用上面的「把目标读到 AIR」再检查。"
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
        }
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

// MARK: - 文件浏览（AFC 根 = /var/mobile/Media）

/// 文件浏览 —— 浏览 `/var/mobile/Media` 这一棵子树（`com.apple.afc` 的根）。
///
/// ## ★ 覆盖范围（界面上必须如实说清）
/// RSD 服务表（64 个服务）里**没有任何服务把根设在 `/var`** —— 所以
/// **`/var` 根、`/var/mobile/Library` 这些列不出来**。能枚举的只有：
/// · `/var/mobile/Media`（AFC，本页）—— DCIM / Downloads / Books / 各 App 共享文件…
/// · `/var/mobile/Library/Logs/CrashReporter`（crashreport AFC，见「概览」的说明）
/// · AIR 中转站
///
/// 而 airlift **本体**只能读写**单个已知文件**、不能枚举目录 —— 所以
/// 「随便输一个路径就能浏览」这种事在 airlift 这条路上做不到，界面上不要暗示可以。
///
/// ## 为什么不做「任意路径输入」
/// 上一版加过一个走 `bad_query_list` 的任意路径入口，已随 v0.3.488 撤掉 ——
/// 本项目走 airlift，不走 bad_query。
private struct AirliftFilesTab: View {
    let module: EscapeModule

    /// 当前根（`media` = /var/mobile/Media；`crash` = /var/mobile/Library/Logs/CrashReporter）
    @State private var root = "media"
    /// 当前路径（**相对当前根**；`/` = 根）
    @State private var path = "/"
    @State private var entries: [AfcEntry] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var previewEntry: AfcEntry?
    @State private var previewText = ""
    @State private var previewLoading = false
    @State private var deleteTarget: AfcEntry?
    @State private var newFolderName = ""
    @State private var creatingFolder = false

    private struct AfcEntry: Identifiable {
        let name: String
        let path: String
        let isDir: Bool
        let size: Int
        var id: String { path }
    }

    var body: some View {
        Form {
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
                    Image(systemName: "externaldrive.fill")
                        .foregroundColor(.accentColor)
                    Text(path == "/" ? rootDisplay : path)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    if loading { ProgressView() }
                }
                HStack {
                    Button {
                        Task { await goUp() }
                    } label: {
                        Label("上一级", systemImage: "arrow.up")
                    }
                    .disabled(path == "/" || loading)
                    Spacer()
                    Button {
                        Task { await load() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            } header: {
                Text("位置")
            } footer: {
                Text("本页所有操作走的是 **AFC**（不是 airlift）—— AFC 在这两个根上是"
                     + "**完整文件管理器**：读 / 写 / 删 / 列 / 建目录。"
                     + "airlift 用于**两个根之外**的单个已知文件（见「自定义覆盖」）。\n\n"
                     + "两个根：**Media**（com.apple.afc）覆盖 DCIM / Downloads / Books / "
                     + "各 App 共享文件；**CrashReporter**（com.apple.crashreportcopymobile）"
                     + "覆盖 /var/mobile/Library/Logs/CrashReporter。\n\n"
                     + "⚠️ **权限边界**：由**系统账号**创建的条目（如 sysdiagnose 归档里的内容）"
                     + "可以读和列，但**删/写会被拒**（AFC 报 PermDenied，airlift 也搬不动）。\n\n"
                     + "❌ **列不出来**：/var 根、/var/mobile/Library、其他 App 容器 —— "
                     + "RSD 服务表（64 个服务）里没有服务把根设在它们上面。")
            }

            if let errorText {
                Section("错误原文") {
                    Text(errorText)
                        .font(.caption)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                if entries.isEmpty && !loading {
                    Text("（空目录）").foregroundColor(.secondary)
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
                            Image(systemName: entry.isDir ? "folder.fill" : fileIcon(entry.name))
                                .foregroundColor(entry.isDir ? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.callout)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if !entry.isDir {
                                    Text(byteText(entry.size))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if entry.isDir {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteTarget = entry
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
                    TextField("新文件夹名", text: $newFolderName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("新建") { Task { await createFolder() } }
                        .buttonStyle(.borderless)
                        .disabled(creatingFolder
                                  || newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("在当前目录新建文件夹")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $previewEntry) { entry in
            NavigationView {
                Group {
                    if previewLoading {
                        ProgressView("读取中…")
                    } else {
                        ScrollView {
                            Text(previewText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                }
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭") { previewEntry = nil }
                    }
                }
            }
        }
        .confirmationDialog(
            "确认删除？",
            isPresented: Binding(get: { deleteTarget != nil },
                                 set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    Task { await delete(target) }
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            if let target = deleteTarget {
                Text("将删除 \(target.path)\(target.isDir ? "（含其中所有内容）" : "")。"
                     + "此操作不可撤销。\n\n"
                     + "注：由系统账号创建的条目会被拒绝删除（权限限制，AFC 与 airlift 都不行）。")
            }
        }
    }

    // MARK: 展示小工具

    private var rootDisplay: String {
        root == "crash" ? "/var/mobile/Library/Logs/CrashReporter" : "/var/mobile/Media"
    }

    private func byteText(_ size: Int) -> String {
        if size >= 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576) }
        if size >= 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return "\(size) B"
    }

    private func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
        case "mp4", "mov", "m4v": return "film"
        case "plist": return "list.bullet.rectangle"
        case "db", "sqlite", "sqlite3": return "cylinder"
        case "zip", "ipa", "tar", "gz": return "archivebox"
        case "log", "txt", "json", "xml": return "doc.text"
        default: return "doc"
        }
    }

    // MARK: 能力调用

    private func call(_ capability: String, _ args: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (_, json) = AirliftPocLog.callRaw(capability, args)
                continuation.resume(returning: json)
            }
        }
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: 操作

    private func load() async {
        loading = true
        defer { loading = false }
        let json = await call("afc.list", jsonString(["root": root, "path": path]))
        let dict = CapJSON.dict(json)
        guard CapJSON.bool(dict, "ok") == true else {
            errorText = CapJSON.string(dict, "error") ?? json
            entries = []
            return
        }
        errorText = nil
        let raw = (dict?["entries"] as? [[String: Any]]) ?? []
        entries = raw.compactMap { item in
            guard let name = item["name"] as? String,
                  let p = item["path"] as? String else { return nil }
            return AfcEntry(name: name,
                            path: p,
                            isDir: (item["isDir"] as? Bool) ?? false,
                            size: (item["size"] as? Int) ?? 0)
        }
    }

    private func enter(_ entry: AfcEntry) async {
        path = entry.path
        await load()
    }

    private func goUp() async {
        guard path != "/" else { return }
        var comps = path.split(separator: "/").map(String.init)
        guard !comps.isEmpty else { return }
        comps.removeLast()
        path = comps.isEmpty ? "/" : "/" + comps.joined(separator: "/")
        await load()
    }

    private func preview(_ entry: AfcEntry) async {
        previewEntry = entry
        previewLoading = true
        previewText = ""
        defer { previewLoading = false }
        let json = await call("afc.read", jsonString(["root": root, "path": entry.path, "encoding": "utf8"]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") == true, let text = CapJSON.string(dict, "data") {
            previewText = text.isEmpty ? "（空文件）" : text
        } else {
            // 二进制按 utf8 读不出来是正常的 —— 如实说明，并提示可以走 AIR 取原始字节
            previewText = (CapJSON.string(dict, "error") ?? json)
                + "\n\n（若是二进制文件，请用「AIR」相关的能力取原始字节；本页只做文本预览。）"
        }
    }

    private func delete(_ entry: AfcEntry) async {
        let json = await call("afc.delete",
                              jsonString(["root": root, "path": entry.path, "recursive": entry.isDir]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") != true {
            errorText = CapJSON.string(dict, "error") ?? json
        }
        await load()
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        creatingFolder = true
        defer { creatingFolder = false }
        let base = path == "/" ? "" : path
        let json = await call("afc.mkdir", jsonString(["root": root, "path": "\(base)/\(name)"]))
        let dict = CapJSON.dict(json)
        if CapJSON.bool(dict, "ok") == true {
            newFolderName = ""
        } else {
            errorText = CapJSON.string(dict, "error") ?? json
        }
        await load()
    }
}
