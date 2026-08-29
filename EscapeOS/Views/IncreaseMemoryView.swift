import SwiftUI

/// 「增加内存限制」入口：移植自 GetMoreRam。
/// 登录后自动加载团队与 App ID 列表，选择目标 App 即可调用 Apple Developer API
/// 为其开启 INCREASED_MEMORY_LIMIT 能力。
struct IncreaseMemoryView: View {
    @StateObject private var settings = MemoryLimitSettings.shared
    @StateObject private var ctrl = IncreaseMemoryController()
    @State private var showDetails = false

    var body: some View {
        List {
            accountSection
            anisetteSection
            if settings.isLoggedIn {
                teamSection
                appSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("增加内存限制")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await ctrl.loadIfNeeded()
        }
        .refreshable {
            await ctrl.reload()
        }
        .alert("操作结果", isPresented: $ctrl.showResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(ctrl.resultMessage)
        }
        .alert("错误", isPresented: $ctrl.showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(ctrl.errorMessage)
        }
    }

    // MARK: - 账户

    private var accountSection: some View {
        Section(header: Text("Apple ID 账户")) {
            if settings.isLoggedIn {
                HStack {
                    Text("账号")
                    Spacer()
                    Text(showDetails ? settings.appleID : settings.maskedAppleID())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button {
                        showDetails.toggle()
                    } label: {
                        Image(systemName: showDetails ? "eye.slash.fill" : "eye.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showDetails ? "隐藏账号" : "显示账号")
                }
                let accountName = settings.accountName
                if !accountName.isEmpty {
                    HStack {
                        Text("账户名称")
                        Spacer()
                        Text(accountName)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                HStack {
                    Text("状态")
                    Spacer()
                    Text("未登录")
                        .foregroundColor(.secondary)
                }
                Text("请在「更多 → 设置 → Apple ID 账户」中登录。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Anisette 服务器

    private var anisetteSection: some View {
        Section(header: Text("Anisette 服务器")) {
            HStack {
                Text("当前服务器")
                Spacer()
                Text(MemoryLimitSettings.host(from: settings.anisetteServer))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 团队

    private var teamSection: some View {
        Section(header: Text("开发者团队")) {
            switch ctrl.teamState {
            case .idle:
                // v0.2.120：`.idle` 曾与 `.loading` 渲染成同一个转圈，
                // "没发起请求"被误认为"正在加载"。现在明确区分。
                HStack {
                    Image(systemName: "exclamationmark.circle").foregroundColor(.orange)
                    Text("尚未加载团队")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("加载") { Task { await ctrl.reload() } }
                }
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在加载团队…")
                        .foregroundColor(.secondary)
                }
            case .failed(let message):
                HStack {
                    Text("加载失败")
                        .foregroundColor(.red)
                    Spacer()
                    Button("重试") { Task { await ctrl.reload() } }
                }
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .loaded:
                if ctrl.teams.isEmpty {
                    Text("账号下没有可用团队")
                        .foregroundColor(.secondary)
                } else {
                    Picker("选择团队", selection: $ctrl.selectedTeamID) {
                        ForEach(ctrl.teams) { team in
                            Text(team.name).tag(team.identifier)
                        }
                    }
                    .onChange(of: ctrl.selectedTeamID) { _ in
                        Task { await ctrl.loadAppIDs() }
                    }
                    if ctrl.teams.count == 1 {
                        Text(ctrl.teams[0].name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - App ID 列表

    private var appSection: some View {
        Section(header: appHeader, footer: appFooter) {
            switch ctrl.appState {
            case .idle:
                if !ctrl.teams.isEmpty {
                    Button("加载 App 列表") { Task { await ctrl.loadAppIDs() } }
                }
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在加载 App 列表…")
                        .foregroundColor(.secondary)
                }
            case .failed(let message):
                Text("加载失败：\(message)")
                    .font(.caption)
                    .foregroundColor(.red)
                Button("重试") { Task { await ctrl.loadAppIDs() } }
            case .loaded:
                if ctrl.apps.isEmpty {
                    Text("该团队下没有 App ID")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(ctrl.apps) { app in
                        AppRowView(
                            app: app,
                            isSelected: ctrl.selectedIDs.contains(app.identifier),
                            isOperating: ctrl.operatingIDs.contains(app.identifier),
                            skipEnabled: ctrl.skipEnabled,
                            onToggleSelection: { ctrl.toggleSelection(app.identifier) },
                            onEnableOne: { Task { await ctrl.enable(for: app) } }
                        )
                    }
                }
            }
        }
    }

    private var appHeader: some View {
        HStack {
            Text("App ID")
            Spacer()
            if ctrl.appState == .loaded, ctrl.eligibleForSelection {
                Button(ctrl.allSelected ? "取消全选" : "全选") {
                    ctrl.toggleSelectAll()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }

    private var appFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("开启后需要重新安装对应 App 才能使 INCREASED_MEMORY_LIMIT 能力生效。")
            if ctrl.appState == .loaded, !ctrl.apps.isEmpty {
                Toggle("跳过已开启的", isOn: $ctrl.skipEnabled)
                    .font(.caption)
            }
            if !ctrl.selectedIDs.isEmpty {
                Button {
                    Task { await ctrl.enableBatch() }
                } label: {
                    HStack {
                        if ctrl.isBatchRunning {
                            ProgressView().controlSize(.small)
                            Text("批量开启中 \(ctrl.batchDone)/\(ctrl.batchTotal)…")
                        } else {
                            Image(systemName: "memorychip")
                            Text("批量开启（\(ctrl.selectedIDs.count)）")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(ctrl.isBatchRunning)
            }
        }
    }
}

// MARK: - App 行

private struct AppRowView: View {
    let app: DeveloperAppID
    let isSelected: Bool
    let isOperating: Bool
    let skipEnabled: Bool
    let onToggleSelection: () -> Void
    let onEnableOne: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.bundleIdentifier)
                    .font(.subheadline)
                Text(app.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if app.hasIncreasedMemory {
                Label("已开启", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else if isOperating {
                ProgressView().controlSize(.small)
            } else {
                Button("开启", action: onEnableOne)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(isOperating)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggleSelection() }
    }
}

// MARK: - Controller

/// 「增加内存限制」页面状态：团队 / App ID 加载与开启操作。
final class IncreaseMemoryController: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published var teamState: LoadState = .idle
    @Published var appState: LoadState = .idle
    @Published var teams: [DeveloperTeam] = []
    @Published var selectedTeamID: String = ""
    @Published var apps: [DeveloperAppID] = []
    @Published var operatingIDs: Set<String> = []          // 当前正在开启的 App（含批量）
    @Published var selectedIDs: Set<String> = []           // 用户勾选待批量开启
    @Published var skipEnabled: Bool = true                // 默认跳过已开启的
    @Published var isBatchRunning = false
    @Published var batchDone = 0
    @Published var batchTotal = 0
    @Published var showResult = false
    @Published var resultMessage = ""
    @Published var showError = false
    @Published var errorMessage = ""
    private var loadedOnce = false

    /// 可被选中的 App（默认排除已开启的；切关「跳过已开启」后包含）
    private var selectableApps: [DeveloperAppID] {
        skipEnabled ? apps.filter { !$0.hasIncreasedMemory } : apps
    }

    var eligibleForSelection: Bool { !selectableApps.isEmpty }
    var allSelected: Bool {
        let ids = selectableApps.map(\.identifier)
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { selectedIDs.contains($0) }
    }

    @MainActor
    private var session: AppleAPISession? {
        guard let dsid = MemoryLimitSettings.shared.dsid,
              let authToken = MemoryLimitSettings.shared.authToken else { return nil }
        return AppleAPISession(dsid: dsid, authToken: authToken, anisetteData: placeholderAnisette())
    }

    /// 占位 anisette（实际请求前会刷新，仅用于构造 session）
    private func placeholderAnisette() -> AnisetteData {
        AnisetteData(
            machineID: "", oneTimePassword: "", localUserID: "", routingInfo: 0,
            deviceUniqueIdentifier: "", deviceSerialNumber: "0", deviceDescription: "",
            date: Date(), locale: Locale.current, timeZone: TimeZone.current
        )
    }

    @MainActor
    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await reload()
    }

    @MainActor
    func reload() async {
        // v0.2.120：以前 session 为 nil 时静默 return，teamState 停在 `.idle`，
        // 而 UI 把 `.idle` 与 `.loading` 渲染成同一个转圈 → 永远"正在加载团队"。
        guard let session else {
            let reason = MemoryLimitSettings.shared.isLoggedIn
                ? "已登录但 Swift 会话缺失（dsid/authToken 为空）"
                : "尚未登录 Apple ID"
            LoginLogger.shared.log("⚠ 增加内存限制：团队列表未发起 —— \(reason)")
            teamState = .failed("\(reason)。请到「更多 → 设置」重新登录 Apple ID。")
            return
        }
        teamState = .loading
        appState = .idle
        // v0.2.116 看门狗：超时强制切失败态，不让 UI 永久停在「正在加载团队…」。
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .loading = self.teamState {
                self.teamState = .failed("加载超时。请下拉刷新重试，或到「更多 → 设置 → Anisette 服务器」换一个服务器。")
                LoginLogger.shared.log("❌ 增加内存限制：团队列表加载看门狗超时")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            let fetched = try await AppleDeveloperAPI.fetchTeams(session: session)
            teams = fetched
            if let first = fetched.first {
                selectedTeamID = first.identifier
            }
            teamState = .loaded
            if !fetched.isEmpty {
                await loadAppIDs()
            }
        } catch {
            teamState = .failed(message(of: error))
        }
    }

    @MainActor
    func loadAppIDs() async {
        guard let session, let team = teams.first(where: { $0.identifier == selectedTeamID }) else { return }
        appState = .loading
        do {
            apps = try await AppleDeveloperAPI.fetchAppIDs(team: team, session: session)
            appState = .loaded
        } catch {
            appState = .failed(message(of: error))
        }
    }

    @MainActor
    func enable(for app: DeveloperAppID) async {
        guard let session, let team = teams.first(where: { $0.identifier == selectedTeamID }) else { return }
        operatingIDs.insert(app.identifier)
        defer { operatingIDs.remove(app.identifier) }
        do {
            let response = try await AppleDeveloperAPI.enableIncreasedMemory(appID: app, team: team, session: session)
            resultMessage = "已为 \(app.bundleIdentifier) 开启增加内存限制。\n\n服务器响应：\n\(response.prefix(300))"
            showResult = true
            await loadAppIDs()  // 刷新状态标记
        } catch {
            errorMessage = message(of: error)
            showError = true
        }
    }

    // MARK: - 批量选择 / 开启

    @MainActor
    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    @MainActor
    func toggleSelectAll() {
        let ids = selectableApps.map(\.identifier)
        if allSelected {
            selectedIDs.subtract(ids)
        } else {
            for id in ids { selectedIDs.insert(id) }
        }
    }

    /// 串行批量开启（每次开启都取独立 Anisette OTP，最稳）。跳过已开启的（若开启「跳过已开启」）。
    @MainActor
    func enableBatch() async {
        guard let session, let team = teams.first(where: { $0.identifier == selectedTeamID }) else { return }
        let targets = apps.filter { selectedIDs.contains($0.identifier) && (!skipEnabled || !$0.hasIncreasedMemory) }
        guard !targets.isEmpty else { return }
        isBatchRunning = true
        batchDone = 0
        batchTotal = targets.count
        defer { isBatchRunning = false }
        var successes: [String] = []
        var failures: [(String, String)] = []
        for app in targets {
            operatingIDs.insert(app.identifier)
            do {
                _ = try await AppleDeveloperAPI.enableIncreasedMemory(appID: app, team: team, session: session)
                successes.append(app.bundleIdentifier)
            } catch {
                failures.append((app.bundleIdentifier, message(of: error)))
            }
            operatingIDs.remove(app.identifier)
            batchDone += 1
        }
        // 一次性汇总报告
        var summary = "批量开启完成（\(successes.count) 成功 / \(failures.count) 失败）。\n"
        if !successes.isEmpty { summary += "\n成功：\n" + successes.map { "• \($0)" }.joined(separator: "\n") }
        if !failures.isEmpty {
            summary += "\n\n失败：\n" + failures.map { "• \($0.0) —— \($0.1)" }.joined(separator: "\n")
        }
        resultMessage = summary
        showResult = true
        selectedIDs.removeAll()
        await loadAppIDs()
    }

    private func message(of error: Error) -> String {
        (error as? AppleAPIError)?.errorDescription ?? error.localizedDescription
    }
}
