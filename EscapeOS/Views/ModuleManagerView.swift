//
//  ModuleManagerView.swift
//  EscapeSpace
//
//  模块管理主界面（v0.3.48，底栏第五个 tab）。
//  参考 KernelSU 的模块管理形态：卡片式模块列表 + 动作按钮手动执行。
//  模块以 .zip 导入（根目录 module.json，规范 escape.module.v1），
//  宿主内置两个官方模块（定位缓存清理 / WLAN 刷新）。
//

import SwiftUI
import UniformTypeIdentifiers

struct ModuleManagerView: View {
    @State private var modules: [EscapeModule] = []
    @State private var isImporting = false
    @State private var runningActionID: String? = nil
    @State private var resultAlert: ModuleRunResult? = nil
    @State private var importError: String? = nil
    @State private var confirmAction: (module: EscapeModule, action: EscapeModuleAction)? = nil

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
        // .fileImporter 在 LiveContainer 客体沙盒有安全域问题——统一走 SharedDocumentPicker
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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: module.icon ?? "shippingbox.fill")
                                .font(.title3)
                                .foregroundColor(accentColor(module))
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(accentColor(module).opacity(0.12))
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(module.name)
                                    .font(.headline)
                                Text("v\(module.version)  ·  \(module.author ?? "未知作者")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        Text(module.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let notes = module.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.vertical, 2)

                    ForEach(module.actions) { action in
                        Button {
                            if let confirm = action.confirm, !confirm.isEmpty {
                                confirmAction = (module, action)
                            } else {
                                run(module: module, action: action)
                            }
                        } label: {
                            HStack {
                                Image(systemName: action.icon ?? "play.circle.fill")
                                Text(action.label)
                                Spacer()
                                if runningActionID == actionKey(module, action) {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(runningActionID != nil)
                    }
                } header: {
                    Text(module.category ?? "模块")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
    }

    private func accentColor(_ module: EscapeModule) -> Color {
        switch module.accentColorName {
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "red": return .red
        default: return .blue
        }
    }

    private func actionKey(_ module: EscapeModule, _ action: EscapeModuleAction) -> String {
        "\(module.id)/\(action.id)"
    }

    // MARK: 逻辑

    private func reload() {
        modules = ModuleService.shared.listModules()
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

/// SharedDocumentPicker 的 SwiftUI 包装（模块导入专用，限 .zip）。
struct ModuleImportPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented else { return }
        // 延迟到下一 runloop，避免在 SwiftUI 更新事务里直接 present
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
