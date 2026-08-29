import Foundation

/// 证书管理（汉化移植自 SideInstaller 的 CertManager）。
///
/// 列出 / 吊销 Apple ID 的开发证书，走 Apple 开发者门户 API
/// （developerservices2.apple.com QH65B2 协议，与「增加内存限制」同一套
/// 认证引擎：SRP-6a + Anisette v3 + 2FA）。纯网络 API 调用，不涉及设备、
/// 配对或隧道，因此不依赖 LocalDevVPN / 本地网络权限。
///
/// 登录态复用 MemoryLimitSettings（Keychain 存 dsid/authToken），
/// 登录 / 2FA 弹窗复用 AppleIDLoginSheet。
@MainActor
final class CertificateManager: ObservableObject {

    /// 团队 / 列表加载状态（与「增加内存限制」保持一致的展示语言）。
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// 全局共享实例：app 启动时后台预热加载证书列表，
    /// 进入「证书管理」页时通常已就绪，无需再等 5~7 秒。
    static let shared = CertificateManager()

    @Published private(set) var certs: [DeveloperCertificate] = []
    @Published private(set) var isSignedIn = false
    @Published private(set) var teamSummary: String?
    /// 列表加载中。
    @Published private(set) var isWorking = false
    /// 正在吊销的证书 id。
    @Published private(set) var revokingID: String?
    @Published var lastError: String?
    /// 上一次错误是否为「会话已过期（1100）」，供 UI 把提示切成「需要重新登录」。
    @Published private(set) var lastErrorIsSessionExpired = false
    /// 已成功加载过一次（区分空列表与未加载）。
    @Published private(set) var hasLoaded = false

    // MARK: - 开发者团队（v0.2.112：对齐「增加内存限制」的团队栏）

    /// 账号下的团队列表。
    @Published private(set) var teams: [DeveloperTeam] = []
    /// 当前选中的团队 id。
    @Published var selectedTeamID: String = ""
    /// 团队列表加载状态。
    @Published private(set) var teamState: LoadState = .idle
    /// 团队列表加载中（与 isWorking 分开，避免团队加载挡住证书刷新）。
    private var isLoadingTeams = false
    /// autoLoad 链式触发：团队拉到后自动拉一次证书。
    private var autoChainCerts = false

    /// 当前选中的团队（没选或选择失效时退回第一个）。
    var selectedTeam: DeveloperTeam? {
        teams.first { $0.identifier == selectedTeamID } ?? teams.first
    }

    /// 进入页面时只自动加载一次，避免 2FA 被拒后每次打开都重新弹。
    private var didAutoLoad = false

    private var settings: MemoryLimitSettings { .shared }

    private var session: AppleAPISession? {
        guard let dsid = settings.dsid, let authToken = settings.authToken else { return nil }
        // anisetteData 仅用于构造 session，实际请求前 makeHeaders 会取全新 OTP。
        return AppleAPISession(dsid: dsid, authToken: authToken, anisetteData: placeholderAnisette())
    }

    /// 占位 anisette（实际请求前会刷新，仅用于构造 session）。
    private func placeholderAnisette() -> AnisetteData {
        AnisetteData(
            machineID: "", oneTimePassword: "", localUserID: "",
            routingInfo: 0, deviceUniqueIdentifier: "", deviceSerialNumber: "",
            deviceDescription: "", date: Date(), locale: Locale.current, timeZone: .current
        )
    }

    // MARK: - 页面动作

    /// 页面打开时安静加载（未登录 / 已加载过则跳过）。
    /// 先拉团队列表（填充「开发者团队」栏），成功后自动拉一次证书。
    func autoLoad() {
        guard !didAutoLoad, !hasLoaded, !isWorking, revokingID == nil else { return }
        guard settings.isLoggedIn, settings.dsid != nil, settings.authToken != nil else { return }
        didAutoLoad = true
        autoChainCerts = true
        loadTeams()
    }

    /// app 启动时后台预热：复用 autoLoad 的守卫（未登录/已加载/加载中都会跳过）。
    /// 单例持有状态，预热结果在进入页面时直接可用。
    func warmUp() {
        autoLoad()
    }

    /// 加载团队列表（「开发者团队」栏）。失败会把原因写进 `lastError`。
    func loadTeams() {
        guard settings.isLoggedIn, let session else {
            lastError = "尚未登录 Apple ID。请先点右上角「登录」并完成两步验证。"
            return
        }
        guard !isLoadingTeams else { return }
        isLoadingTeams = true
        teamState = .loading
        lastError = nil
        Task {
            do {
                let fetched = try await AppleDeveloperAPI.fetchTeams(session: session)
                self.applyTeams(fetched)
                if self.autoChainCerts {
                    self.autoChainCerts = false
                    self.loadCerts()
                }
            } catch {
                let message = self.message(of: error)
                self.teamState = .failed(message)
                self.setError(error)
                self.autoChainCerts = false
            }
            self.isLoadingTeams = false
        }
    }

    /// 写入团队列表并保持选中项有效。
    private func applyTeams(_ fetched: [DeveloperTeam]) {
        teams = fetched
        if selectedTeamID.isEmpty || !fetched.contains(where: { $0.identifier == selectedTeamID }) {
            selectedTeamID = fetched.first?.identifier ?? ""
        }
        teamState = .loaded
    }

    /// 解析出当前要用的团队：优先用已加载的选中项，没有才联网拉一次。
    private func resolveTeam(session: AppleAPISession) async throws -> DeveloperTeam {
        if let team = selectedTeam { return team }
        let fetched = try await AppleDeveloperAPI.fetchTeams(session: session)
        applyTeams(fetched)
        guard let team = selectedTeam else {
            throw AppleAPIError.customError(code: -1, message: "账号下没有可用团队")
        }
        return team
    }

    /// 登录或刷新列表。
    func loadCerts() {
        guard !isWorking, revokingID == nil else { return }
        guard settings.isLoggedIn, let session else {
            lastError = "尚未登录 Apple ID。请先点右上角「登录」并完成两步验证。"
            return
        }
        isWorking = true
        lastError = nil
        Task {
            do {
                let team = try await self.resolveTeam(session: session)
                self.teamSummary = "团队：\(team.name)（\(team.identifier)）"
                let list = try await AppleDeveloperAPI.fetchCertificates(team: team, session: session)
                self.certs = list
                self.hasLoaded = true
                self.isSignedIn = true
            } catch {
                self.setError(error)
            }
            self.isWorking = false
        }
    }

    /// 吊销一张证书并刷新列表。
    func revoke(_ cert: DeveloperCertificate) {
        guard let session, revokingID == nil, !isWorking else { return }
        guard !cert.serialNumber.isEmpty else {
            lastError = "该证书没有序列号，无法吊销。"
            return
        }
        revokingID = cert.id
        lastError = nil
        Task {
            var revoked = false
            do {
                let team = try await self.resolveTeam(session: session)
                try await AppleDeveloperAPI.revokeCertificate(team: team, serialNumber: cert.serialNumber, session: session)
                revoked = true
                let list = try await AppleDeveloperAPI.fetchCertificates(team: team, session: session)
                self.certs = list
            } catch {
                self.setError(error)
            }
            self.revokingID = nil
            if revoked { self.hasLoaded = true }
        }
    }

    /// 批量吊销多张证书并刷新列表（跳过无序列号的）。
    func batchRevoke(_ certsToRevoke: [DeveloperCertificate]) {
        guard let session, !isWorking, revokingID == nil else { return }
        let targets = certsToRevoke.filter { !$0.serialNumber.isEmpty }
        guard !targets.isEmpty else {
            lastError = "所选证书都没有序列号，无法吊销。"
            return
        }
        isWorking = true
        lastError = nil
        Task {
            do {
                let team = try await self.resolveTeam(session: session)
                for cert in targets {
                    try await AppleDeveloperAPI.revokeCertificate(team: team, serialNumber: cert.serialNumber, session: session)
                }
                let list = try await AppleDeveloperAPI.fetchCertificates(team: team, session: session)
                self.certs = list
                self.hasLoaded = true
            } catch {
                self.setError(error)
            }
            self.isWorking = false
        }
    }

    /// 切换账号：清空列表（登录态由 MemoryLimitSettings 管理）。
    func reset() {
        certs = []
        teams = []
        teamState = .idle
        selectedTeamID = ""
        autoChainCerts = false
        hasLoaded = false
        didAutoLoad = false
        lastError = nil
        lastErrorIsSessionExpired = false
        teamSummary = nil
        isSignedIn = false
    }

    // MARK: - 错误文案

    /// 记录错误并标记是否为「会话已过期（1100）」，供 UI 切换提示标题。
    private func setError(_ error: Error) {
        let apiError = error as? AppleAPIError
        lastErrorIsSessionExpired = apiError?.isSessionExpired ?? false
        lastError = apiError?.errorDescription ?? error.localizedDescription
    }

    private func message(of error: Error) -> String {
        (error as? AppleAPIError)?.errorDescription ?? error.localizedDescription
    }
}
