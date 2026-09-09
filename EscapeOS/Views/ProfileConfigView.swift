import SwiftUI

/// v0.3.241：配置描述管理（「更多」板块入口）——
/// iOS 设置描述文件（Configuration Profile）管理，misagent（MCInstall）通道.
/// v0.3.241：空间回收式顶栏（.large + searchable 常驻搜索 UUID/名称）+ 选择模式批量删除
/// + 行完整显示（名称/类型/使用者/UUID 全文/过期时间，对齐爱思助手）+ 全量不过滤.
struct ProfileConfigView: View {
    @State private var profiles: [ProfileConfigService.ConfigurationProfile] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var rawCount = 0
    @State private var parseFailed = 0
    @State private var searchText: String = ""
    @State private var selectionMode = false
    @State private var selectedUUIDs = Set<String>()
    @State private var importFileURL: URL?
    @State private var pendingRemove: ProfileConfigService.ConfigurationProfile?
    @State private var confirmBatch = false
    @State private var toast: String?

    @State private var detailTarget: ProfileConfigService.ConfigurationProfile?

    // v0.3.246：搜索覆盖详情页全部字段——名称/UUID/使用者/组织/类型/文件ID/描述/版本/可移除性
    private var filtered: [ProfileConfigService.ConfigurationProfile] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return profiles }
        return profiles.filter { p in
            p.uuid.lowercased().contains(q)
                || p.name.lowercased().contains(q)
                || (p.organization?.lowercased().contains(q) ?? false)
                || (p.teamName?.lowercased().contains(q) ?? false)
                || (p.identifier?.lowercased().contains(q) ?? false)
                || (p.type?.lowercased().contains(q) ?? false)
                || (p.desc?.lowercased().contains(q) ?? false)
                || (p.version.map { String($0).contains(q) } ?? false)
                || (q == "可移除" && p.removable)
                || (q == "不可移除" && !p.removable)
                || (q == "预置" && p.isProvisioning)
                || (q == "已验证" && p.verified)
        }
    }

    var body: some View {
        List {
            if loading {
                Section {
                    HStack { Spacer(); ProgressView("正在读取设备描述文件…"); Spacer() }
                        .listRowBackground(Color.clear)
                }
            } else if let err = errorText {
                Section {
                    if PairingGate.isPairingError(err) {
                        PairingGuideCard()
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    } else {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            } else if profiles.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.shield").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text(rawCount > 0
                             ? "检测到 \(rawCount) 个描述文件，但 \(parseFailed) 个无法解析"
                             : "设备上没有配置描述文件")
                            .font(.headline)
                        Text(rawCount > 0
                             ? "解析失败的描述文件多为 DER/CMS 格式，请联系开发者扩展解析."
                             : "点击右上角导入 .mobileconfig / .mobileprofile")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .padding(.horizontal, 4)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(filtered) { p in
                        profileRow(p)
                            .listRowBackground(selectionMode && selectedUUIDs.contains(p.uuid)
                                               ? Color.blue.opacity(0.08)
                                               : nil)
                    }
                } header: {
                    Text(selectionMode
                         ? "已选 \(selectedUUIDs.count)/\(filtered.count)"
                         : "设备描述文件（\(filtered.count)）")
                } footer: {
                    Text("预置描述为 App 签名描述；删除设置了移除密码的描述文件会被设备拒绝.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("配置描述管理")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索名称/UUID/描述/文件ID/版本")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if selectionMode {
                        Button(selectedUUIDs.count == filtered.count ? "全不选" : "全选") {
                            if selectedUUIDs.count == filtered.count {
                                selectedUUIDs.removeAll()
                            } else {
                                selectedUUIDs = Set(filtered.map { $0.uuid })
                            }
                        }
                        Button("完成") {
                            selectionMode = false
                            selectedUUIDs.removeAll()
                        }
                    } else {
                        Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                        Button { importFilePicker() } label: { Image(systemName: "plus.circle") }
                            .accessibilityLabel("导入描述文件")
                        Button("选择") {
                            selectionMode = true
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectionMode {
                HStack {
                    Text("已选 \(selectedUUIDs.count) 项").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { confirmBatch = true } label: {
                        Label("批量删除", systemImage: "trash")
                    }
                    .disabled(selectedUUIDs.isEmpty)
                }
                .font(.footnote)
                .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
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
        .sheet(item: $detailTarget) { p in
            profileDetail(p)
        }
        .confirmationDialog("删除 \(selectedUUIDs.count) 个描述文件？", isPresented: $confirmBatch, titleVisibility: .visible) {
            Button("批量删除", role: .destructive) { removeSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将逐个从设备移除选中的描述文件，失败项会跳过并汇总.")
        }
        .confirmationDialog("删除 \(pendingRemove?.name ?? "")？", isPresented: Binding(
            get: { pendingRemove != nil },
            set: { if !$0 { pendingRemove = nil } }
        ), titleVisibility: .visible) {
            Button("删除描述文件", role: .destructive) {
                if let p = pendingRemove { removeOne(p) }
                pendingRemove = nil
            }
            Button("取消", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("将从设备移除该配置描述文件.")
        }
    }

    // MARK: - 行（完整显示，对齐爱思助手）

    @ViewBuilder
    private func profileRow(_ p: ProfileConfigService.ConfigurationProfile) -> some View {
        let isSelected = selectionMode && selectedUUIDs.contains(p.uuid)
        Button {
            if selectionMode {
                if selectedUUIDs.contains(p.uuid) { selectedUUIDs.remove(p.uuid) }
                else { selectedUUIDs.insert(p.uuid) }
            } else {
                // v0.3.246：普通模式点击进详情页（对齐爱思助手：文件ID/版本/使用者/
                // 唯一码/状态/可移除/描述全量展示）
                detailTarget = p
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if selectionMode {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? .blue : .secondary)
                    }
                    Text(p.name).font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if !selectionMode {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(p.isProvisioning ? "预置描述" : (p.type ?? "配置描述"))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue.opacity(0.10)))
                        .foregroundStyle(.blue)
                    if let team = p.teamName, !team.isEmpty {
                        Text(team).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if p.verified {
                        Text("已验证").font(.caption2).foregroundStyle(.green)
                    }
                    Text(p.removable ? "可移除" : "不可移除")
                        .font(.caption2)
                        .foregroundStyle(p.removable ? Color.secondary : Color.orange)
                }
                if let expiry = p.expiry {
                    Text("过期：\(expiry.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(p.uuid)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 详情页（v0.3.246，行样式对齐爱思助手：左标签右值，长文本换行）

    private func detailRow(_ label: String, _ value: String?, monospaced: Bool = false, copyable: Bool = false) -> some View {
        Group {
            if let value, !value.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    if copyable {
                        Text(value)
                            .font(monospaced ? .subheadline.monospaced() : .subheadline)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(value)
                            .font(monospaced ? .subheadline.monospaced() : .subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    private func profileDetail(_ p: ProfileConfigService.ConfigurationProfile) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // v0.3.251: 字段对齐爱思助手 —— 文件 ID = PayloadUUID, 唯一码 = PayloadIdentifier
                    detailRow("文件 ID", p.uuid, monospaced: true, copyable: true)
                    detailRow("文件名称", p.name, copyable: true)
                    detailRow("版本号", p.version.map(String.init))
                    detailRow("类型", p.type ?? (p.isProvisioning ? "预置描述" : nil))
                    detailRow("使用者", p.organization ?? p.teamName)
                    detailRow("唯一码", p.identifier ?? p.uuid, monospaced: true, copyable: true)
                    detailRow("状态", p.verified ? "有效（签名已验证）" : "有效")
                    detailRow("是否可移除", p.removable ? "可移除" : "不可移除（设备端拒绝删除或设置了移除保护）")
                    if let created = p.created {
                        detailRow("创建时间", created.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let expiry = p.expiry {
                        detailRow("过期时间", expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                    if p.contentCount > 0 {
                        detailRow("载荷数量", "\(p.contentCount) 个 payload")
                    }
                    detailRow("文件描述", p.desc ?? "（无描述）")
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("描述文件详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { detailTarget = nil }
                }
            }
        }
    }

    // MARK: - 操作

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    private func importFilePicker() {
        SharedDocumentPicker.present(allowedTypes: [.data], onPicked: { urls in
            importFile(url: urls.first)
        }, onCancelled: {})
    }

    private func refresh() {
        loading = true
        errorText = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try ProfileConfigService.listAll()
                await MainActor.run {
                    profiles = result.profiles
                    rawCount = result.rawCount
                    parseFailed = result.parseFailed
                    selectedUUIDs.removeAll()
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

    private func removeOne(_ p: ProfileConfigService.ConfigurationProfile) {
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

    private func removeSelected() {
        let targets = profiles.filter { selectedUUIDs.contains($0.uuid) }
        guard !targets.isEmpty else { return }
        showToast("正在批量删除…")
        Task.detached(priority: .userInitiated) {
            var ok = 0, failed = 0
            for p in targets {
                do {
                    try ProfileConfigService.remove(uuid: p.uuid)
                    ok += 1
                } catch { failed += 1 }
            }
            let okR = ok, failR = failed
            await MainActor.run {
                selectedUUIDs.removeAll()
                showToast("已删除 \(okR) 项" + (failR > 0 ? "（\(failR) 项失败）" : ""))
                refresh()
            }
        }
    }
}
