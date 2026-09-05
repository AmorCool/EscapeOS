import SwiftUI

/// v0.3.179：系统应用卸载（应用板块入口）——
/// 动态枚举系统应用并识别 Apple 官方"可卸载"标记（removableSystemApp），
/// 支持勾选批量卸载。卸载的系统应用可从 App Store 重新下载恢复.
struct SystemAppUninstallView: View {
    @State private var apps: [LSAppWorkspace.SystemApp] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var showConfirm = false
    @State private var resultMessage: String?
    @State private var workspaceUnavailable = false

    var body: some View {
        List {
            if workspaceUnavailable {
                Section {
                    Label("无法访问 LSApplicationWorkspace（私有 API 不可用）", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在扫描系统应用…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("共 \(apps.count) 个系统应用，其中可卸载 \(apps.filter { $0.removable }.count) 个.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !isLoading {
                Section {
                    ForEach(apps) { app in
                        HStack(spacing: 10) {
                            if app.removable {
                                Image(systemName: selected.contains(app.bundleID)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(selected.contains(app.bundleID) ? .blue : .secondary)
                                    .onTapGesture { toggle(app.bundleID) }
                            } else {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.footnote)
                                    .foregroundColor(app.removable ? .primary : .secondary)
                                Text(app.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if !app.removable {
                                Text("系统组件")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if app.removable { toggle(app.bundleID) }
                        }
                    }
                } header: {
                    HStack {
                        Text("系统应用")
                        Spacer()
                        Button {
                            load()
                        } label: {
                            Image(systemName: "arrow.clockwise").imageScale(.small)
                        }
                    }
                } footer: {
                    Text("仅 Apple 官方标记为可卸载的系统应用提供勾选（removableSystemApp）.卸载后可从 App Store 重新下载恢复，但仍请谨慎操作.")
                }
            }
        }
        .navigationTitle("系统应用卸载")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                HStack {
                    Text("已选 \(selected.count) 个")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("卸载所选", role: .destructive) {
                        showConfirm = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .alert("确认卸载？", isPresented: $showConfirm) {
            Button("卸载 \(selected.count) 个应用", role: .destructive) { uninstallSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从设备移除所选系统应用.这些应用可从 App Store 重新下载恢复，但卸载期间相关功能不可用.")
        }
        .alert(item: Binding(
            get: { resultMessage.map { AlertText(message: $0) } },
            set: { resultMessage = $0?.message }
        )) { item in
            Alert(title: Text("卸载结果"), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .onAppear { if apps.isEmpty { load() } }
    }

    struct AlertText: Identifiable {
        let id = UUID()
        let message: String
    }

    private func toggle(_ bundleID: String) {
        if selected.contains(bundleID) {
            selected.remove(bundleID)
        } else {
            selected.insert(bundleID)
        }
    }

    private func load() {
        isLoading = true
        selected = []
        DispatchQueue.global(qos: .userInitiated).async {
            let workspaceReady = LSAppWorkspace.shared != nil
            let list = LSAppWorkspace.shared?.systemApps() ?? []
            DispatchQueue.main.async {
                workspaceUnavailable = !workspaceReady
                apps = list
                isLoading = false
            }
        }
    }

    private func uninstallSelected() {
        let targets = selected
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = 0
            var failed: [String] = []
            for bundleID in targets {
                if LSAppWorkspace.shared.uninstallSystemApp(bundleID: bundleID) {
                    ok += 1
                } else {
                    failed.append(bundleID)
                }
            }
            DispatchQueue.main.async {
                selected = []
                resultMessage = "成功卸载 \(ok) 个" + (failed.isEmpty ? "" : "；失败 \(failed.count) 个：\(failed.joined(separator: ", "))")
                load()
            }
        }
    }
}
