//
//  ModuleManagerView.swift
//  EscapeSpace
//
//  模块管理主界面（v0.3.48，底栏第五个 tab；v0.3.49 卡片化重构）。
//  卡片风格对齐 KernelSU / 爱思模块市场：名称 + 启用 Toggle + 版本/作者 +
//  描述 + 动作按钮 + 底部「打开(WebView) / 卸载」胶囊按钮。
//

import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ModuleManagerView: View {
    @State private var modules: [EscapeModule] = []
    @State private var enabledMap: [String: Bool] = [:]
    @State private var isImporting = false
    @State private var runningActionID: String? = nil
    @State private var resultAlert: ModuleRunResult? = nil
    @State private var showingLogFor: EscapeModule? = nil
    // 安装详情（KernelSU 风格终端日志）
    @State private var showInstallSheet = false
    @State private var installLog: [String] = []
    @State private var installFinished = false
    @State private var installSucceeded = false
    @State private var confirmAction: (module: EscapeModule, action: EscapeModuleAction)? = nil
    @State private var uninstallTarget: EscapeModule? = nil
    @State private var actionMenuModule: EscapeModule? = nil
    @State private var showModuleSettings = false
    @State private var webviewModule: EscapeModule? = nil
    @State private var searchText = ""

    var body: some View {
        Group {
            if modules.isEmpty {
                emptyState
            } else {
                moduleList
            }
        }
        .navigationTitle("模块")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                // 对齐更多板块右上角设置：齿轮 → 弹窗设置页
                Button {
                    showModuleSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.large)
                }
                .accessibilityLabel("模块设置")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("导入模块")
            }
        }
        .sheet(isPresented: $showModuleSettings) {
            NavigationView {
                List {
                    Section {
                        Toggle(isOn: Binding(
                            get: { ModuleService.restoreOnUpgrade },
                            set: { ModuleService.restoreOnUpgrade = $0 }
                        )) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("覆盖安装后恢复内置模块")
                            }
                        }
                        .tint(.blue)
                    } footer: {
                        Text("开启后，覆盖安装新版本 IPA 时内置模块自动恢复；关闭后卸载即永久卸载（重新导入 .zip 可恢复）。")
                    }

                    Section {
                        Button {
                            ModuleService.shared.restoreBundledModules()
                            reload()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("立即恢复内置模块")
                            }
                        }
                        .tint(.blue)
                    } footer: {
                        Text("内置模块被卸载后未自动回归时（如同一安装包反复覆盖），点此手动恢复。")
                    }
                }
                .navigationTitle("模块设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { showModuleSettings = false }
                    }
                }
            }
        }
        .onAppear(perform: reload)

        .sheet(item: $showingLogFor) { mod in
            ModuleLogView(module: mod) { showingLogFor = nil }
        }
        .refreshable { reload() }
        .background(
            ModuleImportPicker(isPresented: $isImporting) { urls in
                handleImport(urls)
            }
        )
        .sheet(isPresented: $showInstallSheet, onDismiss: { installLog = [] }) {
            ModuleInstallSheet(
                lines: installLog,
                finished: installFinished,
                succeeded: installSucceeded,
                onClose: { showInstallSheet = false }
            )
            .interactiveDismissDisabled(!installFinished)
        }
        .alert("执行结果", isPresented: Binding(
            get: { resultAlert != nil },
            set: { if !$0 { resultAlert = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultAlert?.message ?? "")
        }
        .confirmationDialog(
            confirmAction?.action.confirm ?? "",
            isPresented: Binding(
                get: { confirmAction != nil },
                set: { if !$0 { confirmAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("执行") {
                if let pair = confirmAction {
                    run(module: pair.module, action: pair.action)
                }
                confirmAction = nil
            }
            Button("取消", role: .cancel) { confirmAction = nil }
        }
        .confirmationDialog(
            "确定卸载模块「\(uninstallTarget?.name ?? "")」？",
            isPresented: Binding(
                get: { uninstallTarget != nil },
                set: { if !$0 { uninstallTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            
                        // v0.3.111：模块日志查看器（导出/复制/清空）
                        Button {
                            showingLogFor = module
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text("日志")
                            }
                        }
                        .tint(.secondary)
                        Button("卸载", role: .destructive) {
                if let m = uninstallTarget {
                    ModuleService.shared.delete(id: m.id)
                    reload()
                }
                uninstallTarget = nil
            }
            Button("取消", role: .cancel) { uninstallTarget = nil }
        }
        .confirmationDialog(
            "选择要执行的动作",
            isPresented: Binding(
                get: { actionMenuModule != nil },
                set: { if !$0 { actionMenuModule = nil } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(actionMenuModule?.actions ?? []) { act in
                Button(act.label) {
                    if let m = actionMenuModule {
                        run(module: m, action: act)
                    }
                    actionMenuModule = nil
                }
            }
            Button("取消", role: .cancel) { actionMenuModule = nil }
        }
        .sheet(isPresented: Binding(
            get: { webviewModule != nil },
            set: { if !$0 { webviewModule = nil } }
        )) {
            if let m = webviewModule, let root = ModuleService.shared.webrootURL(for: m) {
                NavigationView {
                    ModuleWebView(startPage: root.appendingPathComponent("index.html"),
                                  readAccessRoot: root)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle(m.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("关闭") { webviewModule = nil }
                            }
                        }
                }
            }
        }
    }

    // MARK: 子视图

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无模块", systemImage: "shippingbox")
        } description: {
            Text("点击右上角导入 .zip 模块\n（规范 escape.module.v1）")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var moduleList: some View {
        List {
            // 搜索无结果时也必须保留 List（.searchable 挂在上面，
            // 切换视图会把搜索框整个卸载）
            if filteredModules.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredModules) { module in
                    Section {
                        moduleCard(module)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索模块 / 作者 / 描述")
    }

    /// KernelSU 风格模块卡片：名称+Toggle / 版本作者 / 描述 / 动作 / 打开+卸载
    /// 二进制模块控制区：运行状态 + WebUI + 停止/启动
    @ViewBuilder
    private func binaryControls(_ module: EscapeModule) -> some View {
        let runner = BinaryModuleRunner.shared
        let running = runner.isRunning(module: module)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(running ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(running
                     ? "后台运行中\(runner.runningProcesses[module.id].map { " (pid \($0))" } ?? "")"
                     : (module.autoStart == true || module.binary?.autoStart == true) ? "自启动待命" : "未运行")
                    .font(.footnote)
                    .foregroundColor(running ? .green : .secondary)
                Spacer()
                if running {
                    if let url = runner.webURL(for: module) {
                        Button {
                            runner.openWebUI(module: module)
                        } label: {
                            Label("WebUI", systemImage: "safari")
                                .font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                    Button {
                        runner.stop(module: module)
                    } label: {
                        Text("停止")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                // 启动按钮移至底栏左侧（与卸载对称，用户规范）——此处不再重复
            }

            if let err = runner.startErrors[module.id] {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
    }

    /// 模块卡片（逐像素对齐截图：白卡片 / 黑粗标题 / 灰版本作者描述 / 蓝Toggle / 灰胶囊底栏）
    private func moduleCard(_ module: EscapeModule) -> some View {
        let enabled = enabledMap[module.id] ?? true
        let hasWeb = ModuleService.shared.webrootURL(for: module) != nil
        let running = BinaryModuleRunner.shared.isRunning(module: module)

        return VStack(alignment: .leading, spacing: 6) {
            // 标题 + Toggle
            HStack(alignment: .top) {
                Text(module.name)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { enabledMap[module.id] ?? true },
                    set: { newValue in
                        ModuleService.shared.setEnabled(id: module.id, newValue)
                        enabledMap[module.id] = newValue
                    }
                ))
                .labelsHidden()
                .tint(.blue)
            }

            // 版本 / 作者（截图同款灰字两行）
            Text("版本: v\(module.version)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("作者: \(module.author ?? "未知")")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // 描述（灰字自动换行）
            Text(module.description)
                .font(.subheadline)
                .foregroundColor(.secondary)

            // 签名徽章（热补丁/二进制模块）
            if module.isHotfixModule || module.isBinaryModule {
                Label("官方签名已验证", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            // 二进制模块运行区（自启动服务：alist 等）
            if module.isBinaryModule && enabled {
                binaryControls(module)
            }

            Divider()

            // 底栏：启动/执行 + 打开 在左，卸载在右（截图同款灰胶囊黑字）
            HStack(spacing: 12) {
                if enabled && module.isBinaryModule && !running {
                    pill(label: "启动", icon: "play.fill") {
                        BinaryModuleRunner.shared.start(module: module, automatic: false)
                    }
                }
                if enabled && !module.actions.isEmpty {
                    pill(label: "执行", icon: "play.fill") {
                        handleRun(module: module)
                    }
                }
                if enabled && module.isLuaModule {
                    pill(label: "运行", icon: "play.fill") {
                        runLua(module: module)
                    }
                }
                if hasWeb && enabled {
                    pill(label: "打开", icon: "chevron.left.forwardslash.chevron.right") {
                        webviewModule = module
                    }
                }
                Spacer()
                if ModuleService.shared.isInPlaceBundled(module.id) {
                    // 内置原地模块不可卸载（用户规范：置灰）
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("卸载")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary.opacity(0.4))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color(.systemGray6)))
                } else {
                    pill(label: "卸载", icon: "trash") {
                        uninstallTarget = module
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(enabled ? 1 : 0.55)
    }

    /// 动作分发：单动作直接跑；多动作弹选单
    private func handleRun(module: EscapeModule) {
        if module.actions.count == 1 {
            run(module: module, action: module.actions[0])
        } else {
            actionMenuModule = module
        }
    }

    /// 灰底胶囊（截图风格：systemGray6 底 + 黑字黑图标 + .plain）
    private func pill(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.subheadline.weight(.medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color(.systemGray6)))
        }
        .buttonStyle(.plain)
    }

    private func actionKey(_ module: EscapeModule, _ action: EscapeModuleAction) -> String {
        "\(module.id)/\(action.id)"
    }

    // MARK: 逻辑

    /// 搜索过滤：模块名 / 作者 / 描述
    private var filteredModules: [EscapeModule] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return modules }
        return modules.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            ($0.author ?? "").localizedCaseInsensitiveContains(q) ||
            $0.description.localizedCaseInsensitiveContains(q)
        }
    }

    private func reload() {
        modules = ModuleService.shared.listModules()
        enabledMap = Dictionary(uniqueKeysWithValues: modules.map {
            ($0.id, ModuleService.shared.isEnabled(id: $0.id))
        })
    }

    private func handleImport(_ urls: [URL]) {
        guard let url = urls.first else { return }
        // KernelSU 风格：弹出安装详情（终端日志），完成后右下角关闭
        installLog = ["- 开始导入：\(url.lastPathComponent)"]
        installFinished = false
        installSucceeded = false
        showInstallSheet = true
        let appendLog: (String) -> Void = { line in
            DispatchQueue.main.async { self.installLog.append(line) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let module = try ModuleService.shared.importZip(at: url, log: appendLog)
                DispatchQueue.main.async {
                    self.reload()
                    self.installLog.append("✓ 导入成功：\(module.name) v\(module.version)")
                    if module.isBinaryModule, module.autoStart == true || module.binary?.autoStart == true {
                        self.installLog.append("- 二进制模块随宿主自启动")
                    }
                    self.installFinished = true
                    self.installSucceeded = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.installLog.append("! 导入失败：\(error.localizedDescription)")
                    self.installFinished = true
                    self.installSucceeded = false
                }
            }
        }
    }

    private func run(module: EscapeModule, action: EscapeModuleAction) {
        let key = actionKey(module, action)
        runningActionID = key
        Task.detached(priority: .userInitiated) {
            var result: ModuleRunResult
            do {
                let summary = try ModuleService.shared.run(action: action)
                result = ModuleRunResult(message: summary)
            } catch {
                result = ModuleRunResult(message: "执行失败：\(error.localizedDescription)")
            }
            await MainActor.run {
                runningActionID = nil
                resultAlert = result
            }
        }
    }

    /// Lua 模块运行（v1.2）：调用内置解释器执行入口脚本，结果弹窗展示
    private func runLua(module: EscapeModule) {
        runningActionID = module.id
        Task.detached(priority: .userInitiated) {
            let (ret, output) = ModuleService.shared.runLuaModule(module)
            await MainActor.run {
                runningActionID = nil
                let message = ret == 0
                    ? "Lua 模块运行完成\n\(output)"
                    : "Lua 模块运行失败（码 \(ret)）\n\(output)"
                resultAlert = ModuleRunResult(message: message)
            }
        }
    }
}

struct ModuleRunResult {
    let message: String
}

/// 模块 WebView 页（KernelSU webroot 对齐）：加载模块目录内 index.html，
/// 读权限限定在模块目录内。
struct ModuleWebView: UIViewRepresentable {
    let startPage: URL
    let readAccessRoot: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        // 时间戳查询参数破缓存，保证升级模块后加载新内容
        var comps = URLComponents(url: startPage, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970)))]
        if let busted = comps.url {
            wv.loadFileURL(busted, allowingReadAccessTo: readAccessRoot)
        } else {
            wv.loadFileURL(startPage, allowingReadAccessTo: readAccessRoot)
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// SharedDocumentPicker 的 SwiftUI 包装（模块导入专用，限 .zip）。
struct ModuleImportPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented else { return }
        DispatchQueue.main.async {
            guard self.isPresented else { return }
            self.isPresented = false
            SharedDocumentPicker.present(
                allowedTypes: [UTType.zip],
                allowsMultipleSelection: false,
                asCopy: true,
                onPicked: { urls in
                    self.onPicked(urls)
                },
                onCancelled: nil
            )
        }
    }
}

/// 安装界面（对齐 KernelSU 官方 FlashScreen Material 版）：
/// 普通页面背景 + 等宽小字日志整页滚动 + 自动滚底，
/// 标题随状态变化（安装中/安装成功/安装失败），完成后右下角悬浮「关闭」按钮。
struct ModuleInstallSheet: View {
    let lines: [String]
    let finished: Bool
    let succeeded: Bool
    let onClose: () -> Void

    private var title: String {
        if !finished { return "安装中" }
        return succeeded ? "安装成功" : "安装失败"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                ScrollViewReader { proxy in
                    // 官方为单段 Monospace bodySmall 文本 + 8dp padding，页面默认背景
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: lines.count) { _ in
                        // 官方：日志更新即滚到底部
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lines.count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if finished {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { onClose() }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("!") { return .red }
        if line.hasPrefix("✓") { return .green }
        return .primary
    }
}


// v0.3.111：模块日志查看器（v0.3.111：每个已安装模块可查看/导出/复制/清空运行日志）
struct ModuleLogView: View {
    let module: EscapeModule
    var onClose: () -> Void
    @State private var logText: String = ""
    @State private var showCopied = false
    @State private var showClearConfirm = false

    private var logFile: URL { ModuleService.shared.installURL(for: module.id).appendingPathComponent("run.log") }
    private var goStderr: URL { ModuleService.shared.installURL(for: module.id).appendingPathComponent("data/go_stderr.log") }

    var body: some View {
        NavigationView {
            ScrollView {
                Text(logText.isEmpty ? "（暂无日志）" : logText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .navigationTitle("\(module.name) 日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { onClose() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = logText
                        showCopied = true
                    } label: { Image(systemName: "doc.on.doc") }
                    Menu {
                        Button { reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        ShareLink(item: logFile) { Label("导出 run.log", systemImage: "square.and.arrow.up") }
                        ShareLink(item: goStderr) { Label("导出 go_stderr.log", systemImage: "square.and.arrow.up") }
                        Divider()
                        Button(role: .destructive) { showClearConfirm = true } label: {
                            Label("清空日志", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onAppear { reload() }
            .alert("已复制", isPresented: $showCopied) { Button("好", role: .cancel) {} }
            .confirmationDialog("确认清空？", isPresented: $showClearConfirm) {
                Button("清空 run.log", role: .destructive) { tryClear(target: logFile) }
                Button("清空 go_stderr.log", role: .destructive) { tryClear(target: goStderr) }
                Button("取消", role: .cancel) {}
            } message: { Text("删除后不可恢复。") }
        }
    }

    private func reload() {
        let combined = [logFile, goStderr].map { url -> String in
            (try? String(contentsOf: url, encoding: .utf8)).map { "[\(url.lastPathComponent)]\n\($0)\n" } ?? ""
        }.joined()
        logText = combined.isEmpty ? "" : combined
    }

    private func tryClear(target: URL) {
        try? FileManager.default.removeItem(at: target)
        reload()
    }
}
