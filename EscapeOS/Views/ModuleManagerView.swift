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
    @State private var importError: String? = nil
    @State private var confirmAction: (module: EscapeModule, action: EscapeModuleAction)? = nil
    @State private var uninstallTarget: EscapeModule? = nil
    @State private var actionMenuModule: EscapeModule? = nil
    @State private var webviewModule: EscapeModule? = nil

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
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("导入模块")
            }
        }
        .onAppear(perform: reload)
        .refreshable { reload() }
        .background(
            ModuleImportPicker(isPresented: $isImporting) { urls in
                handleImport(urls)
            }
        )
        .alert("执行结果", isPresented: Binding(
            get: { resultAlert != nil },
            set: { if !$0 { resultAlert = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultAlert?.message ?? "")
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
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
            ForEach(modules) { module in
                Section {
                    moduleCard(module)
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            }

            // 覆盖安装后恢复内置模块的开关（UserDefaults 跨安装保留，
            // 卸载标记绑定宿主 build——build 变化且开关开才恢复）
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
            } header: {
                Text("设置")
            } footer: {
                Text("关闭后，卸载内置模块即使覆盖安装新 IPA 也不会回归；开启后，安装新版本 IPA 时内置模块自动恢复。")
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
    }

    /// KernelSU 风格模块卡片：名称+Toggle / 版本作者 / 描述 / 动作 / 打开+卸载
    /// 模块卡片（逐像素对齐截图：白卡片 / 黑粗标题 / 灰版本作者描述 / 蓝Toggle / 灰胶囊底栏）
    private func moduleCard(_ module: EscapeModule) -> some View {
        let enabled = enabledMap[module.id] ?? true
        let hasWeb = ModuleService.shared.webrootURL(for: module) != nil

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

            Divider()

            // 底栏：执行 + 打开 在左，卸载在右（截图同款灰胶囊黑字）
            HStack(spacing: 12) {
                if enabled && !module.actions.isEmpty {
                    pill(label: "执行", icon: "play.fill") {
                        handleRun(module: module)
                    }
                }
                if hasWeb && enabled {
                    pill(label: "打开", icon: "chevron.left.forwardslash.chevron.right") {
                        webviewModule = module
                    }
                }
                Spacer()
                pill(label: "卸载", icon: "trash") {
                    uninstallTarget = module
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

    private func reload() {
        modules = ModuleService.shared.listModules()
        enabledMap = Dictionary(uniqueKeysWithValues: modules.map {
            ($0.id, ModuleService.shared.isEnabled(id: $0.id))
        })
    }

    private func handleImport(_ urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let module = try ModuleService.shared.importZip(at: url)
            reload()
            resultAlert = ModuleRunResult(
                message: "模块「\(module.name)」v\(module.version) 导入成功")
        } catch {
            importError = error.localizedDescription
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
