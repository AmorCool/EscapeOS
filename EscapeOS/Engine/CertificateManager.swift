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

    @Published private(set) var certs: [DeveloperCertificate] = []
    @Published private(set) var isSignedIn = false
    @Published private(set) var teamSummary: String?
    /// 列表加载中。
    @Published private(set) var isWorking = false
    /// 正在吊销的证书 id。
    @Published private(set) var revokingID: String?
    @Published var lastError: String?
    /// 已成功加载过一次（区分空列表与未加载）。
    @Published private(set) var hasLoaded = false

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
    func autoLoad() {
        guard !didAutoLoad, !hasLoaded, !isWorking, revokingID == nil else { return }
        guard settings.isLoggedIn, settings.dsid != nil, settings.authToken != nil else { return }
        didAutoLoad = true
        loadCerts()
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
                let teams = try await AppleDeveloperAPI.fetchTeams(session: session)
                guard let team = teams.first else {
                    throw AppleAPIError.customError(code: -1, message: "账号下没有可用团队")
                }
                teamSummary = "团队：\(team.name)（\(team.identifier)）"
                let list = try await AppleDeveloperAPI.fetchCertificates(team: team, session: session)
                certs = list
                hasLoaded = true
                isSignedIn = true
            } catch {
                lastError = (error as? AppleAPIError)?.errorDescription ?? error.localizedDescription
            }
            isWorking = false
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
                let teams = try await AppleDeveloperAPI.fetchTeams(session: session)
                guard let team = teams.first else {
                    throw AppleAPIError.customError(code: -1, message: "账号下没有可用团队")
                }
                try await AppleDeveloperAPI.revokeCertificate(team: team, serialNumber: cert.serialNumber, session: session)
                revoked = true
                let list = try await AppleDeveloperAPI.fetchCertificates(team: team, session: session)
                certs = list
            } catch {
                lastError = (error as? AppleAPIError)?.errorDescription ?? error.localizedDescription
            }
            revokingID = nil
            if revoked { hasLoaded = true }
        }
    }

    /// 切换账号：清空列表（登录态由 MemoryLimitSettings 管理）。
    func reset() {
        certs = []
        hasLoaded = false
        didAutoLoad = false
        lastError = nil
        teamSummary = nil
        isSignedIn = false
    }
}
