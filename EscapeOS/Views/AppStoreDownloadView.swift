import SwiftUI

/// App Store IPA 下载（功能移植自 asspp / ApplePackage，v0.2.148+）。
///
/// 与「IPA 侧载」的区别：
/// - IPA 侧载：用 Apple ID 登录开发者服务，**自己签名**后安装
/// - 本页：用 Apple ID 登录 **App Store**，**下载官方正版 IPA**（含 FairPlay
///   sinf 签名），下载完直接交给「IPA 安装」在线安装 —— 与爱思助手同类。
///
/// 底层走移植进来的 ApplePackage（网络层已用 URLSession 重写，ZIP 用
/// 项目已有的 SWCompression），无需再次签名。
///
/// 账户登录：优先复用「更多 → 设置 → Apple ID 账户」里已登录的 Apple ID
///（同一份邮箱 + 密码走 iTunes 认证即可），无需在 App Store 下载里再登录一次；
/// 遇到双重认证等情况时仍可手动添加账户。

/// 把 iTunes 认证错误转成中文可读提示，对「plist 格式异常」做专门说明。
/// 该错误来自移植进来的 ApplePackage（`Authenticate.parseResponse` 的
/// PropertyListSerialization 解析失败），根因需真机日志取证，这里只做清晰化。
func iTunesAuthErrorMessage(_ error: Error) -> String {
    let desc = error.localizedDescription
    if desc.contains("未能读取数据") || desc.localizedCaseInsensitiveContains("property list") {
        return "Apple 返回的认证数据格式异常（非预期 plist）。常见原因：会话 / 令牌过期、网络异常或 Anisette 失效。建议：先在「更多 → 设置 → Apple ID 账户」重新登录或检查网络；若开启双重认证，请改用手动添加账户并填验证码。"
    }
    return "登录失败：\(desc)"
}

/// 把 `AnisetteData` 转成 App Store iTunes 认证（`native/fast/`）所需的设备认证请求头。
/// 复用 Swift 认证引擎已验证可用的头部集合（X-Apple-I-MD / X-Apple-I-MD-M 等）。
/// 缺失这些头时 Apple 边缘会直接返回 403 HTML（ipatool 机制分析已确认）。
///
/// - 注意：anisette OTP 一次性，调用方应在**每次认证尝试**时重新取全新 anisette 再调本函数。
func buildAppStoreAnisetteHeaders(for data: AnisetteData) -> [(String, String)] {
    let df = AppleAuthenticator.dateFormatter
    return [
        ("X-Apple-I-MD", data.oneTimePassword),
        ("X-Apple-I-MD-M", data.machineID),
        ("X-Mme-Device-Id", data.deviceUniqueIdentifier),
        ("X-Apple-I-MD-LU", data.localUserID),
        ("X-Apple-I-MD-RINFO", "\(data.routingInfo)"),
        ("X-Apple-I-SRL-NO", data.deviceSerialNumber),
        ("X-Apple-I-Client-Time", df.string(from: data.date)),
        ("X-Apple-I-TimeZone", data.timeZone.abbreviation() ?? "PST"),
        ("X-MMe-Client-Info", data.deviceDescription),
        ("X-Apple-Locale", data.locale.identifier),
    ]
}

/// 取一次全新 anisette 并转成 iTunes 认证头，供 `Authenticator.authenticate(anisetteProvider:)` 使用。
/// - 必须传 `refresh: true`：Apple 的 anisette OTP 一次性，每次认证尝试都需要新的设备
///   标识/头；若复用同一 OTP，Apple 边缘会静默拒绝（表现为 204/403/301 等）。
func fetchFreshAppStoreAnisetteHeaders() async throws -> [(String, String)] {
    let anisette = try await AnisetteProvider.shared.getAnisetteDataWithFallback(refresh: true)
    return buildAppStoreAnisetteHeaders(for: anisette)
}

/// 双重认证验证码输入：把 App Store 登录的 2FA 入口统一到这一个组件。
/// `AppStoreDownloadView`（设置里已登录的 Apple ID）与 `AddAccountSheet`（手动添加）
/// 共用，避免两处各写一套 alert（审计 Q12「2FA 弹窗双入口重构」）。
struct TwoFactorCodePrompt: View {
    @Binding var isPresented: Bool
    @Binding var code: String
    let email: String
    let onVerify: () -> Void

    var body: some View {
        EmptyView()
            .alert("来自 \(email) 的 2FA 验证码", isPresented: $isPresented) {
                TextField("6 位验证码", text: $code)
                    .keyboardType(.numberPad)
                Button("验证") { onVerify() }
                Button("取消", role: .cancel) {
                    isPresented = false
                    code = ""
                }
            } message: {
                Text("验证码会发送到该账户的受信任设备（其他 iPhone/iPad/Mac 的通知）或绑定的手机短信.\n没收到？确认账号绑定了受信任手机号，或在 appleid.apple.com 触发一次登录请求.")
            }
    }
}

struct AppStoreDownloadView: View {
    @State private var accounts: [AppStoreAccount] = []
    @State private var selectedEmail: String = ""
    @State private var showAddAccount = false
    @State private var showLoginLog = false
    @State private var busy = false
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var toast: String?
    // 2FA（双重认证）内联处理：与 AddAccountSheet 共用 TwoFactorCodePrompt（审计 Q12）。
    @State private var showTwoFactor = false
    @State private var twoFactorCode = ""
    @State private var twoFactorEmail = ""
    @State private var pendingEmail = ""
    @State private var pendingPassword = ""

    private let store = AppStoreDownloadStore.shared
    // v0.3.3：SAP 状态条（JIT 模式 + 资产包下载进度）
    @ObservedObject private var sapStatus = SapStatusModel.shared
    // v0.3.17：PC 签名服务已移除，保留变量防编译错（不展示）

    var body: some View {
        List {
            sapStatusSection
            accountSection
            downloadSection
            if errorMessage != nil { errorSection }
            statusSection
            deviceSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Store 下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showLoginLog = true
                } label: {
                    Label("登录日志", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $showLoginLog) {
            LoginLogView()
        }
        .background(
            TwoFactorCodePrompt(
                isPresented: $showTwoFactor,
                code: $twoFactorCode,
                email: twoFactorEmail,
                onVerify: verifyTwoFactor
            )
        )
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheet { account in
                store.add(account)
                reload()
                selectedEmail = account.email
                toast = "已添加账户：\(account.email)"
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
        .onAppear { reload() }
    }

    // MARK: - 子视图

    /// v0.3.6：SAP 状态条——JIT 模式 + 资产包进度。JIT 行可点击重测
    /// （StikDebug 开启 JIT 后回来点一下即更新，不再依赖登录流程内的探测）。
    private var sapStatusSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "cpu.fill")
                    .font(.footnote)
                    .foregroundStyle(.blue)
                Text("签名引擎：本机 TCI")
                    .font(.footnote)
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .font(.footnote)
                    .foregroundStyle(.blue)
                Text(sapStatus.progress.map { "资产包 \(Int($0 * 100))%（\(sapStatus.bytesText)）" }
                     ?? "资产包：\(sapStatus.phaseText)")
                    .font(.footnote)
            }
        } footer: {
            Text("TCI 解释器模式运行（无需 JIT/StikDebug）。资产包仅首次下载（约 36MB），之后走本地缓存。")
        }
    }



    private var accountSection: some View {
        Section {
            if accounts.isEmpty {
                Text("尚未添加 App Store 账户")
                    .foregroundColor(.secondary)
            } else {
                ForEach(accounts, id: \.email) { account in
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email)
                                .font(.subheadline)
                            Text("商店：\(account.store)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if account.email == selectedEmail {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedEmail = account.email }
                }
                .onDelete { indexSet in
                    for index in indexSet { store.remove(accounts[index].email) }
                    reload()
                }
            }
            // 复用「更多 → 设置 → Apple ID 账户」里已登录的 Apple ID：
            // 同一份邮箱 + 密码即可走 iTunes 认证拿到 AppStoreAccount，无需再单独登录一次。
            // appleID 是非可选 String（空串表示未登录），不能用 if let 绑定。
            let settingsEmail = MemoryLimitSettings.shared.appleID
            if !settingsEmail.isEmpty {
                Button {
                    useSettingsAppleID()
                } label: {
                    Label("使用「更多」已登录的 Apple ID", systemImage: "person.crop.circle.badge.checkmark")
                }
                .foregroundColor(.blue)
                .disabled(busy)
            }

            Button {
                showAddAccount = true
            } label: {
                Label("添加 App Store 账户", systemImage: "person.badge.plus")
            }
            .foregroundColor(.blue)
        } header: {
            Text("账户")
        } footer: {
            Text("已登录「更多 → 设置 → Apple ID 账户」时，点上方按钮即可直接复用该 Apple ID 下载 App Store 应用，无需重复登录；遇到双重认证等情况可改用下方手动添加并填写验证码。凭据只保存在本机。")
        }
    }

    private var downloadSection: some View {
        Section {
            NavigationLink {
                AppStoreSearchView(email: selectedEmail)
            } label: {
                Label("搜索并下载应用", systemImage: "magnifyingglass")
            }
            .foregroundColor(.blue)
            .disabled(selectedEmail.isEmpty)
        } header: {
            Text("下载")
        } footer: {
            Text(selectedEmail.isEmpty ? "请先添加并选择一个账户。" : "下载完成的 IPA 会保存在本机「已下载」列表，可一键发送给「IPA 安装」在线安装。")
        }
    }

    private var errorSection: some View {
        Section {
            Text(errorMessage ?? "")
                .font(.footnote)
                .foregroundColor(.red)
        } header: {
            Label("错误", systemImage: "exclamationmark.triangle")
        }
    }

    private var statusSection: some View {
        Section {
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status.isEmpty ? "处理中…" : status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text(status.isEmpty ? "就绪" : status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("状态")
        }
    }

    /// v0.3.167：设备标识（guid）展示与重置——Apple 边缘对已标记的标识持续拒
    ///（native/fast 301/404）；重置 = 换新"虚拟机器"身份，配合换网络/换
    /// Anisette 服务器排查登录被拒.
    @ViewBuilder
    private var deviceSection: some View {
        Section {
            LabeledContent("设备标识（guid）") {
                Text(Configuration.deviceIdentifier)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Anisette 服务器") {
                Text(AnisetteProvider.shared.currentServer)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            Button {
                store.resetDeviceIdentifier()
                toast = "已重置设备标识：\(Configuration.deviceIdentifier)（请重新登录试）"
            } label: {
                Label("重置设备标识", systemImage: "arrow.counterclockwise")
            }
            .tint(.blue)
        } header: {
            Text("设备与认证")
        } footer: {
            Text("登录持续被拒（403/301/404）时重置设备标识，并尝试切换 Anisette 服务器或更换网络后重试.")
        }
    }

    // MARK: - 操作

    private func reload() {
        accounts = store.accounts
        if selectedEmail.isEmpty { selectedEmail = accounts.first?.email ?? "" }
    }

    /// 复用「更多 → 设置 → Apple ID 账户」里已登录的 Apple ID（同一份邮箱 + 密码）
    /// 走 iTunes 认证拿到 AppStoreAccount，避免用户在 App Store 下载里再登录一次。
    ///
    /// 注意：侧载的 GrandSlam 会话与 App Store 的 iTunes 会话**令牌不互通**，
    /// 这里只是复用**凭据**（邮箱+密码），仍要调一次 `Authenticator.authenticate`
    /// 走 iTunes 流程拿 `passwordToken` / `dsPersonId` / cookie。开启双重认证时
    /// 该接口会失败，此时回退到手动添加账户并填写验证码。
    private func useSettingsAppleID() {
        let settings = MemoryLimitSettings.shared
        let email = settings.appleID
        guard !email.isEmpty,
              let password = settings.password(forHistory: email), !password.isEmpty else {
            errorMessage = "未找到「更多 → 设置 → Apple ID 账户」的登录凭据，请先在那里登录，或点下方手动添加。"
            return
        }
        let pw = password
        pendingEmail = email
        pendingPassword = pw
        busy = true
        status = "正在用设置中的 Apple ID 登录 App Store…"
        LoginLogger.shared.log("App Store 下载：开始用「更多」已登录的 Apple ID（\(email)）走 iTunes 认证")
        Task {
            do {
                let account = try await Authenticator.authenticate(
                    email: email,
                    password: pw,
                    anisetteProvider: { try await fetchFreshAppStoreAnisetteHeaders() }
                )
                await MainActor.run {
                    store.add(account)
                    reload()
                    selectedEmail = account.email
                    busy = false
                    status = "已用设置中的 Apple ID 登录"
                    toast = "已用「更多」中的 Apple ID 登录：\(account.email)"
                }
                LoginLogger.shared.log("App Store 下载：iTunes 认证成功，store=\(account.store)，appleId=\(account.appleId ?? "未知")")
            } catch {
                let desc = error.localizedDescription
                await MainActor.run {
                    busy = false
                    // 双重认证：与原手动添加入口共用同一套 2FA 弹窗（审计 Q12 单一入口），
                    // 不再要求用户「改用下方手动添加」，直接在设置登录流程内补全验证码。
                    if desc.contains("Authentication requires verification code") {
                        twoFactorEmail = email
                        twoFactorCode = ""
                        showTwoFactor = true
                    } else {
                        errorMessage = iTunesAuthErrorMessage(error)
                    }
                }
                LoginLogger.shared.log("App Store 下载：iTunes 认证失败 - \(desc)")
            }
        }
    }

    /// 设置登录流程内的 2FA 重试：用同一份（邮箱+密码）+ 用户输入的验证码重新走 iTunes 认证。
    private func verifyTwoFactor() {
        let email = pendingEmail
        let password = pendingPassword
        let code = twoFactorCode
        showTwoFactor = false
        twoFactorCode = ""
        guard !email.isEmpty, !password.isEmpty else { return }
        busy = true
        status = "正在验证双重认证…"
        LoginLogger.shared.log("App Store 下载：设置登录流程内 2FA 重试 \(email)（含验证码：是）")
        Task {
            do {
                let account = try await Authenticator.authenticate(
                    email: email,
                    password: password,
                    code: code,
                    anisetteProvider: { try await fetchFreshAppStoreAnisetteHeaders() }
                )
                await MainActor.run {
                    store.add(account)
                    reload()
                    selectedEmail = account.email
                    busy = false
                    status = "已用设置中的 Apple ID 登录"
                    toast = "已用「更多」中的 Apple ID 登录：\(account.email)"
                }
                LoginLogger.shared.log("App Store 下载：2FA 重试成功，store=\(account.store)")
            } catch {
                let desc = error.localizedDescription
                await MainActor.run {
                    busy = false
                    errorMessage = iTunesAuthErrorMessage(error)
                }
                LoginLogger.shared.log("App Store 下载：2FA 重试失败 - \(desc)")
            }
        }
    }
}
