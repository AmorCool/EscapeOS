import SwiftUI
import UniformTypeIdentifiers

/// 描述文件管理（App Expiry，汉化移植自 StikDebug 的 ProfileView）。
///
/// 与 StikDebug 原版的差异（按用户要求优化）：
/// 1. 「未匹配描述文件」不再挤成一堆——按 AppIDName（证书名）分组，
///    每组显示软件名 + 最新过期时间 + 状态颜色，一眼分清属于哪个软件；
/// 2. 新增批量选择删除（含全选），可一次清理多个过期 / 冗余描述文件。
struct AppExpiryView: View {
    @State private var matchedEntries: [MatchedAppEntry] = []
    @State private var unmatchedGroups: [UnmatchedGroup] = []
    @State private var isLoading = true
    @State private var loadError = ""
    @State private var showLoadError = false
    @State private var searchText = ""

    // 批量模式
    @State private var isEditing = false
    @State private var selectedUUIDs: Set<String> = []
    @State private var showDeleteConfirm = false

    // 单个删除 / 导入 / 导出
    @State private var removeTarget: ProvisioningProfileStore.ProfileInfo?
    @State private var showRemoveConfirm = false
    @State private var showImporter = false
    @State private var exportTarget: ProvisioningProfileStore.ProfileInfo?
    @State private var showExporter = false
    @State private var exportURL: URL?
    @State private var infoMessage = ""
    @State private var showInfo = false

    private var allUUIDs: [String] {
        (matchedEntries.flatMap(\.profiles) + unmatchedGroups.flatMap(\.profiles)).map(\.id)
    }

    /// 搜索过滤（匹配证书名 / 应用名 / Bundle ID / UUID / application-identifier）。
    private var filteredMatchedEntries: [MatchedAppEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return matchedEntries }
        return matchedEntries.compactMap { entry in
            let profiles = entry.profiles.filter { profileMatchesQuery($0, query) }
            guard !profiles.isEmpty || entry.name.lowercased().contains(query) || entry.bundleID.lowercased().contains(query) else {
                return nil
            }
            return MatchedAppEntry(name: entry.name, bundleID: entry.bundleID, profiles: profiles)
        }
    }

    private var filteredUnmatchedGroups: [UnmatchedGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return unmatchedGroups }
        return unmatchedGroups.compactMap { group in
            let profiles = group.profiles.filter { profileMatchesQuery($0, query) }
            guard !profiles.isEmpty || group.appName.lowercased().contains(query) else { return nil }
            return UnmatchedGroup(appName: group.appName, profiles: profiles)
        }
    }

    private func profileMatchesQuery(_ profile: ProvisioningProfileStore.ProfileInfo, _ query: String) -> Bool {
        profile.appName.lowercased().contains(query) ||
        profile.id.lowercased().contains(query) ||
        profile.appId.lowercased().contains(query)
    }

    var body: some View {
        List {
            if isLoading && matchedEntries.isEmpty && unmatchedGroups.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("正在读取设备描述文件…")
                        Spacer()
                    }
                }
            } else if matchedEntries.isEmpty && unmatchedGroups.isEmpty {
                Section {
                    Text("没有找到描述文件。")
                        .foregroundStyle(.secondary)
                    Text("可通过右上角 + 导入 .mobileprovision 描述文件；设备侧载应用的描述文件会显示在这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                if !matchedEntries.isEmpty {
                    Section {
                        ForEach(filteredMatchedEntries) { entry in
                            matchedAppRow(entry)
                        }
                    } header: {
                        Label("已匹配应用", systemImage: "app.badge.checkmark")
                    } footer: {
                        Text("按应用的 application-identifier 与描述文件匹配，显示最近与最佳匹配的描述文件。")
                    }
                }

                if !unmatchedGroups.isEmpty {
                    Section {
                        ForEach(filteredUnmatchedGroups) { group in
                            unmatchedGroupRow(group)
                        }
                    } header: {
                        Label("未匹配描述文件（按证书分组）", systemImage: "doc.badge.gearshape")
                    } footer: {
                        Text("设备上无法对应到已安装 App 的描述文件，按 AppIDName（证书名）分组展示，方便识别与清理。")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("描述文件管理")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索证书名 / 名称 / UUID")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isEditing {
                    Button(isAllSelected ? "取消全选" : "全选") {
                        toggleSelectAll()
                    }
                    Button("完成") {
                        isEditing = false
                        selectedUUIDs.removeAll()
                    }
                } else {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    Button(isEditing ? "完成" : "编辑") {
                        isEditing.toggle()
                        selectedUUIDs.removeAll()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                deleteBar
            }
        }
        .onAppear {
            if matchedEntries.isEmpty && unmatchedGroups.isEmpty {
                Task { await load() }
            }
        }
        .documentPicker(
            isPresented: $showImporter,
            allowedTypes: [UTType(filenameExtension: "mobileprovision") ?? .data],
            allowsMultipleSelection: false
        ) { urls in
            Task { await handleImport(urls: urls) }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: ProfileExportDocument(data: exportTarget?.data ?? Data()),
            contentType: .data,
            defaultFilename: exportTarget.map { "\($0.appName).mobileprovision" } ?? "profile.mobileprovision"
        ) { _ in }
        .alert("删除描述文件", isPresented: $showRemoveConfirm) {
            Button("删除", role: .destructive) {
                if let target = removeTarget {
                    doRemove([target])
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(removeTarget.map { "删除 \($0.appName)（UUID: \($0.id)）？\n关联该描述文件的应用可能无法再运行。" } ?? "")
        }
        .alert("批量删除", isPresented: $showDeleteConfirm) {
            Button("删除 \(selectedUUIDs.count) 个", role: .destructive) {
                let targets = allProfiles().filter { selectedUUIDs.contains($0.id) }
                doRemove(targets)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除选中的 \(selectedUUIDs.count) 个描述文件。\n关联这些描述文件的应用可能无法再运行。")
        }
        .alert("操作失败", isPresented: $showLoadError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(loadError)
        }
        .alert("提示", isPresented: $showInfo) {
            Button("好", role: .cancel) {}
        } message: {
            Text(infoMessage)
        }
    }

    // MARK: - 行

    private func matchedAppRow(_ entry: MatchedAppEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "app.fill")
                    .foregroundStyle(AppTheme.accent)
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let best = entry.profiles.min(by: { $0.daysRemaining < $1.daysRemaining }) {
                    Text("\(expiryLabel(best)) · \(best.formattedDate)")
                        .font(.caption)
                        .foregroundStyle(expiryColor(best.daysRemaining))
                }
            }
            Text(entry.bundleID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ForEach(entry.profiles) { profile in
                profileRow(profile)
            }
        }
        .padding(.vertical, 4)
    }

    private func unmatchedGroupRow(_ group: UnmatchedGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.badge.clock")
                    .foregroundStyle(AppTheme.accent)
                Text(group.appName)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer()
                if let latest = group.profiles.min(by: { $0.daysRemaining < $1.daysRemaining }) {
                    Text("\(expiryLabel(latest)) · \(latest.formattedDate)")
                        .font(.caption)
                        .foregroundStyle(expiryColor(latest.daysRemaining))
                }
                Text("\(group.profiles.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(group.profiles) { profile in
                profileRow(profile)
            }
        }
        .padding(.vertical, 4)
    }

    private func profileRow(_ profile: ProvisioningProfileStore.ProfileInfo) -> some View {
        HStack(spacing: 10) {
            if isEditing {
                Image(systemName: selectedUUIDs.contains(profile.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedUUIDs.contains(profile.id) ? AppTheme.accent : Color.secondary)
                    .onTapGesture {
                        toggleSelection(profile.id)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.formattedDate)
                        .font(.caption.monospaced())
                        .foregroundStyle(expiryColor(profile.daysRemaining))
                    Text(expiryLabel(profile))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(expiryColor(profile.daysRemaining))
                }
                Text("UUID: \(profile.id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            if !isEditing {
                Button {
                    exportTarget = profile
                    showExporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)

                Button {
                    removeTarget = profile
                    showRemoveConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing { toggleSelection(profile.id) }
        }
        .padding(.vertical, 2)
    }

    private var deleteBar: some View {
        HStack(spacing: 12) {
            Button(isAllSelected ? "取消全选" : "全选") {
                toggleSelectAll()
            }
            .font(.subheadline.weight(.semibold))

            Spacer()

            Text("已选 \(selectedUUIDs.count) 个")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                showDeleteConfirm = true
            } label: {
                Text("删除选中")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(selectedUUIDs.isEmpty ? Color.gray : Color.red))
            }
            .disabled(selectedUUIDs.isEmpty)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 数据

    private func allProfiles() -> [ProvisioningProfileStore.ProfileInfo] {
        matchedEntries.flatMap(\.profiles) + unmatchedGroups.flatMap(\.profiles)
    }

    private var isAllSelected: Bool {
        let all = allUUIDs
        return !all.isEmpty && all.allSatisfy { selectedUUIDs.contains($0) }
    }

    private func toggleSelection(_ uuid: String) {
        if selectedUUIDs.contains(uuid) {
            selectedUUIDs.remove(uuid)
        } else {
            selectedUUIDs.insert(uuid)
        }
    }

    private func toggleSelectAll() {
        if isAllSelected {
            selectedUUIDs.removeAll()
        } else {
            selectedUUIDs = Set(allUUIDs)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (profiles, apps) = try await Task.detached(priority: .userInitiated) {
                (try ProvisioningProfileStore.fetchAllProfiles(),
                 try ProvisioningProfileStore.fetchSideloadedApps())
            }.value

            // 已匹配：按 app 分组
            var matched: [MatchedAppEntry] = []
            var unmatchedByCert: [String: [ProvisioningProfileStore.ProfileInfo]] = [:]

            for app in apps {
                let appId = app.applicationIdentifier ?? app.bundleID
                let appProfiles = profiles.filter { $0.appId == appId || wildcardMatch(profile: $0.appId, value: appId) }
                if appProfiles.isEmpty {
                    // 没有匹配描述文件的应用仍然列出（显示"无匹配"）
                    matched.append(MatchedAppEntry(name: app.name, bundleID: app.bundleID, profiles: []))
                } else {
                    matched.append(MatchedAppEntry(name: app.name, bundleID: app.bundleID, profiles: appProfiles))
                }
            }

            let matchedUUIDs = Set(matched.flatMap(\.profiles).map(\.id))
            for profile in profiles where !matchedUUIDs.contains(profile.id) {
                unmatchedByCert[profile.appName, default: []].append(profile)
            }

            await MainActor.run {
                self.matchedEntries = matched
                self.unmatchedGroups = unmatchedByCert
                    .map { UnmatchedGroup(appName: $0.key, profiles: $0.value) }
                    .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                showLoadError = true
            }
        }
    }

    private func wildcardMatch(profile pattern: String, value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return value.range(of: "^" + escaped + "$", options: .regularExpression) != nil
    }

    /// 导入描述文件（统一走 SharedDocumentPicker：asCopy 已把文件拷入沙盒，
    /// 不再需要 security-scoped 访问——`.fileImporter` 在 LC/证书直装环境
    /// 弹出不可靠且 security-scoped URL 读取常失败，v0.2.75 起统一）。
    private func handleImport(urls: [URL]) async {
        do {
            guard let url = urls.first else {
                throw NSError(domain: "AppExpiry", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择文件"])
            }
            let data = try Data(contentsOf: url)
            try ProvisioningProfileStore.addProfile(data)
            infoMessage = "描述文件添加成功。"
            showInfo = true
            await load()
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                showLoadError = true
            }
        }
    }

    private func doRemove(_ targets: [ProvisioningProfileStore.ProfileInfo]) {
        guard !targets.isEmpty else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    for profile in targets {
                        try ProvisioningProfileStore.removeProfile(uuid: profile.id)
                    }
                }.value
                selectedUUIDs.removeAll()
                infoMessage = "已删除 \(targets.count) 个描述文件。"
                showInfo = true
                await load()
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    showLoadError = true
                }
            }
        }
    }

    // MARK: - 过期状态

    private func expiryLabel(_ profile: ProvisioningProfileStore.ProfileInfo) -> String {
        let days = profile.daysRemaining
        if days == Int.max { return "未知" }
        if days < 0 { return "已过期 \(-days) 天" }
        if days == 0 { return "今天到期" }
        return "剩 \(days) 天"
    }

    private func expiryColor(_ days: Int) -> Color {
        switch days {
        case ..<0: return .red
        case 0...1: return .red
        case 2...3: return .orange
        case 4...5: return .yellow
        case 6...: return .green
        default: return .secondary
        }
    }
}

// MARK: - 模型

private struct MatchedAppEntry: Identifiable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
    let profiles: [ProvisioningProfileStore.ProfileInfo]
}

private struct UnmatchedGroup: Identifiable {
    var id: String { appName }
    let appName: String
    let profiles: [ProvisioningProfileStore.ProfileInfo]
}

private struct ProfileExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
