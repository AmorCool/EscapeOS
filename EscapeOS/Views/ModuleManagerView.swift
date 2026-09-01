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
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
    }

    /// KernelSU 风格模块卡片：名称+Toggle / 版本作者 / 描述 / 动作 / 打开+卸载
    private func moduleCard(_ module: EscapeModule) -> some View {
        let enabled = enabledMap[module.id] ?? true
        let hasWeb = ModuleService.shared.webrootURL(for: module) != nil

        return VStack(alignment: .leading, spacing: 8) {
            // 第一行：名称 + 启用 Toggle
            HStack(alignment: .top) {
                Text(module.name)
                    .font(.title3.weight(.semibold))
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

            // 版本 / 作者
            VStack(alignment: .leading, spacing: 2) {
                Text("版本: v\(module.version)\(module.versionCode.map { " (\($0))" } ?? "")")
                Text("作者: \(module.author ?? "未知")")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)

            // 描述
            Text(module.description)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(6)

            // 动作区（禁用时隐藏）
            if enabled {
                Divider()
                ForEach(module.actions) { action in
                    Button {
                        run(module: module, action: action)
                    } label: {
                        HStack {
                            Image(systemName: action.icon ?? "play.circle.fill")
                            Text(action.label)
                            Spacer()
                            if runningActionID == actionKey(module, action) {
                                ProgressView()
                            } else {
                                Text("执行")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(runningActionID != nil)
                }

                if let notes = module.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else {
                Divider()
                Label("已禁用——启用后动作可用", systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Divider()

            // 底部操作条：打开(WebView) + 卸载
            HStack {
                if hasWeb && enabled {
                    Button {
                        webviewModule = module
                    } label: {
                        Label("打开", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                }
                Spacer()
                Button {
                    uninstallTarget = module
                } label: {
                    Label("卸载", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
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
