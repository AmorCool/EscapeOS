import SwiftUI

/// v0.3.229：配置描述管理（「更多」板块入口）——
/// iOS 设置描述文件（Configuration Profile，.mobileconfig/.mobileprofile）管理。
/// 参考 pymobiledevice3 profile 命令（list / install / remove），底层 misagent（MCInstall）。
struct ProfileConfigView: View {
    @State private var profiles: [ProfileConfigService.ConfigurationProfile] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var importFileURL: URL?
    @State private var pendingRemove: ProfileConfigService.ConfigurationProfile?
    @State private var toast: String?

    var body: some View {
        List {
            if loading {
                Section {
                    HStack { Spacer(); ProgressView("正在读取设备描述文件…"); Spacer() }
                        .listRowBackground(Color.clear)
                }
            } else if let err = errorText {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if profiles.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.shield").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("设备上没有配置描述文件").font(.headline)
                        Text("点击右上角导入 .mobileconfig / .mobileprofile").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("设备描述文件（\(profiles.count)）") {
                    ForEach(profiles) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.subheadline)
                            if let org = p.organization, !org.isEmpty {
                                Text(org).font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                if let t = p.type { Text(t).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                                Text("UUID ····\(String(p.uuid.suffix(8)))")
                                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                if p.verified {
                                    Text("已验证").font(.caption2).foregroundStyle(.green)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingRemove = p
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("删除需在系统设置中输入移除密码（若该描述文件设置了 HasRemovalPasscode）。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("配置描述管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    Button {
                        SharedDocumentPicker.present(allowedTypes: [.data], onPicked: { urls in
                            importFile(url: urls.first)
                        }, onCancelled: {})
                    } label: { Image(systemName: "plus.circle") }
                        .accessibilityLabel("导入描述文件")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Capsule().fill(Color(.systemBackground)))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .task { refresh() }
        .confirmationDialog("删除 \(pendingRemove?.name ?? "")？", isPresented: Binding(
            get: { pendingRemove != nil },
            set: { if !$0 { pendingRemove = nil } }
        ), titleVisibility: .visible) {
            Button("删除描述文件", role: .destructive) {
                if let p = pendingRemove { remove(p) }
                pendingRemove = nil
            }
            Button("取消", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("将从设备移除该配置描述文件（UUID ····\(String(pendingRemove?.uuid.suffix(8) ?? ""))）。")
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    private func refresh() {
        loading = true
        errorText = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try ProfileConfigService.listConfigurationProfiles()
                await MainActor.run {
                    profiles = result
                    loading = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    loading = false
                }
            }
        }
    }

    /// 导入 .mobileconfig / .mobileprofile（misagent Install——同 pymobiledevice3 profile install）
    private func importFile(url: URL?) {
        guard let url else { return }
        guard let data = try? Data(contentsOf: url) else {
            showToast("读取描述文件失败")
            return
        }
        showToast("正在安装…")
        Task.detached(priority: .userInitiated) {
            do {
                try ProfileConfigService.install(data)
                await MainActor.run {
                    showToast("已安装：\(url.lastPathComponent)")
                    refresh()
                }
            } catch {
                await MainActor.run {
                    showToast(error.localizedDescription)
                }
            }
        }
    }

    private func remove(_ p: ProfileConfigService.ConfigurationProfile) {
        showToast("正在删除…")
        Task.detached(priority: .userInitiated) {
            do {
                try ProfileConfigService.remove(uuid: p.uuid)
                await MainActor.run {
                    showToast("已删除：\(p.name)")
                    refresh()
                }
            } catch {
                await MainActor.run {
                    showToast(error.localizedDescription)
                    refresh()
                }
            }
        }
    }
}
