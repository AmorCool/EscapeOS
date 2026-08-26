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
            case .idle, .loading:
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
        Section(header: Text("App ID"), footer: Text("开启后需要重新安装对应 App 才能使 INCREASED_MEMORY_LIMIT 能力生效。")) {
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
                        HStack {
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
                            } else {
                                Button {
                                    Task { await ctrl.enable(for: app) }
                                } label: {
                                    if ctrl.enablingBundleID == app.bundleIdentifier {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("开启")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .disabled(ctrl.enablingBundleID != nil)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Controller

/// 「增加内存限制」页面状态：团队 / App ID 加载与开启操作。
final class IncreaseMemoryController: ObservableObject {
    enum LoadState {
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
    @Published var enablingBundleID: String?
    @Published var showResult = false
    @Published var resultMessage = ""
    @Published var showError = false
    @Published var errorMessage = ""
    private var loadedOnce = false

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
        guard let session else { return }
        teamState = .loading
        appState = .idle
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
        enablingBundleID = app.bundleIdentifier
        defer { enablingBundleID = nil }
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

    private func message(of error: Error) -> String {
        (error as? AppleAPIError)?.errorDescription ?? error.localizedDescription
    }
}
