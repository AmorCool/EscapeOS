import SwiftUI
import UniformTypeIdentifiers

/// 登录 Apple ID 的弹窗.
/// 调用本地自带的 Apple 认证引擎（SRP-6a + Anisette v3）完成真实登录，
/// 而非仅保存凭据.需要两步验证时会弹出验证码输入框.
struct AppleIDLoginSheet: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var ctrl = AppleLoginController()

    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var rememberAccount = true
    @State private var showImporter = false
    @State private var importError: String?
    @State private var showLog = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Apple ID")) {
                    HStack {
                        TextField("邮箱", text: $email)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        if !MemoryLimitSettings.shared.loginHistory.isEmpty {
                            Menu {
                                ForEach(MemoryLimitSettings.shared.loginHistory, id: \.self) { account in
                                    Button {
                                        fillHistory(account)
                                    } label: {
                                        Label(account, systemImage: "clock.arrow.circlepath")
                                    }
                                    Button(role: .destructive) {
                                        MemoryLimitSettings.shared.removeLoginHistory(account)
                                    } label: {
                                        Label("删除 \(account)", systemImage: "xmark.circle")
                                    }
                                }
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    HStack {
                        Group {
                            if showPassword {
                                TextField("密码", text: $password)
                            } else {
                                SecureField("密码", text: $password)
                            }
                        }
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section {
                    Toggle(isOn: $rememberAccount) {
                        Label("记住账户", systemImage: "bookmark")
                    }
                } footer: {
                    Text("开启后，登录成功的账户会保存在「最近登录」列表中，之后可从下拉菜单一键登录；未开启则不记录.")
                }

                Section {
                    Button(action: { Task { await signIn() } }) {
                        HStack {
                            if ctrl.isAuthenticating {
                                ProgressView().controlSize(.small)
                                Text("正在登录…")
                            } else {
                                Text("登录")
                            }
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || ctrl.isAuthenticating)
                }

                Section(header: Text("SideStore"), footer: Text("从 SideStore 设置中导出账户 JSON，可免去手动输入账号密码，并直接带入设备认证所需的 adi.pb 与本地标识.")) {
                    Button("导入 SideStore 账户文件") {
                        showImporter = true
                    }
                }
            }
            .navigationTitle("登录 Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showLog = true
                    } label: {
                        Label("诊断日志", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showLog) {
                // 这里是**登录**面板里的「诊断日志」→ 只显示 AppleID 登录/认证引擎那一类。
                // 此前传 `[.appStore]`，而 `.appStore` 被商店业务与登录引擎共用，
                // 于是商店的商品页/下载日志也会混进来（用户实测指正）。
                LoginLogView(categories: [.appleID])
            }
            .documentPicker(isPresented: $showImporter, allowedTypes: [.json]) { urls in
                handleImport(urls)
            }
            .alert("导入失败", isPresented: .constant(importError != nil)) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .alert("登录失败", isPresented: .constant(ctrl.authError != nil)) {
                Button("好", role: .cancel) { ctrl.authError = nil }
            } message: {
                Text(ctrl.authError ?? "")
            }
            .alert("两步验证", isPresented: $ctrl.showTwoFactorAlert) {
                TextField("6 位验证码", text: $ctrl.twoFactorCode)
                    .keyboardType(.numberPad)
                Button("验证") {
                    let code = ctrl.twoFactorCode
                    ctrl.showTwoFactorAlert = false
                    let reply = ctrl.twoFactorReply
                    ctrl.twoFactorReply = nil
                    reply?(code)
                }
                Button("取消", role: .cancel) {
                    ctrl.showTwoFactorAlert = false
                    let reply = ctrl.twoFactorReply
                    ctrl.twoFactorReply = nil
                    reply?(nil)
                }
            } message: {
                Text("Apple 已向你的受信任设备或短信发送验证码，请输入以完成登录.")
            }
        }
    }

    @MainActor
    private func signIn() async {
        ctrl.isAuthenticating = true
        ctrl.authError = nil
        LoginLogger.shared.log("▶ 用户点击登录: \(email.lowercased())")
        // SRP 自检：只跑一次并缓存结果（PASS 后不再重复跑，避免每次登录的 PBKDF2 开销）
        // v2：BigInt 除法更换实现后强制重跑一次，验证新除法
        if UserDefaults.standard.string(forKey: "SRPTestResult_v2") == nil {
            let selfTest = await Task.detached(priority: .utility) {
                GSAAuth.runSelfTest()
            }.value
            UserDefaults.standard.set(selfTest, forKey: "SRPTestResult_v2")
            LoginLogger.shared.log("SRP 自检: \(selfTest)")
        }
        do {
            // v0.2.115：改用带重试 + 服务器轮换的入口.清数据后首次登录要走完整
            // provisioning，遇到服务器侧 -45025 / -45003 / WebSocket 断开时自动换
            // 下一个 Anisette 服务器重试，而不是直接把错误抛给用户.
            let anisette = try await AnisetteProvider.shared.getAnisetteDataWithFallback()
            LoginLogger.shared.log("✓ Anisette 获取成功，进入 GrandSlam 握手")
            let (account, session) = try await AppleAuthenticator.authenticate(
                appleID: email,
                password: password,
                anisetteData: anisette
            ) { @Sendable reply in
                // Swift 6：@Sendable → 非 MainActor 隔离，才可作为回调传入
                // nonisolated 的 authenticate（ctrl 已随 AppleLoginController
                // 标 @MainActor 而成为 Sendable，可被安全捕获）.
                DispatchQueue.main.async {
                    ctrl.twoFactorCode = ""
                    ctrl.twoFactorReply = reply
                    ctrl.showTwoFactorAlert = true
                }
            } refreshAnisette: { @Sendable in
                // 2FA 通过后必须换新 OTP（一次性，首次握手已消费），否则 Apple 拒绝 -22421
                // Swift 6：同上，@Sendable → 非 MainActor 隔离（方法本身 nonisolated async）.
                try await AnisetteProvider.shared.getAnisetteDataWithFallback(refresh: true)
            }
            MemoryLimitSettings.shared.completeSignIn(email: email, password: password, account: account, session: session)
            if !rememberAccount {
                MemoryLimitSettings.shared.removeLoginHistory(email)
            }
            LoginLogger.shared.log("✓ 登录成功，凭据已保存: \(account.appleID)")
            await MainActor.run {
                ctrl.isAuthenticating = false
                dismiss()
            }
        } catch {
            let message = (error as? AppleAPIError)?.errorDescription ?? error.localizedDescription
            LoginLogger.shared.log("❌ 登录失败: \(message)")
            await MainActor.run {
                ctrl.isAuthenticating = false
                ctrl.authError = message
            }
        }
    }

    /// 从「最近登录」选择一个账户：回填邮箱与密码并立即登录.
    private func fillHistory(_ account: String) {
        email = account
        password = MemoryLimitSettings.shared.password(forHistory: account) ?? ""
        guard !password.isEmpty else { return }
        Task { await signIn() }
    }

    private func handleImport(_ urls: [URL]) {
        do {
            guard let url = urls.first else { throw MemoryLimitError.missingField }
            let data = try Data(contentsOf: url)
            let account = try JSONDecoder().decode(SideStoreAccount.self, from: data)
            try MemoryLimitSettings.shared.importSideStoreAccount(account)
            dismiss()
        } catch let error as MemoryLimitError {
            importError = error.localizedDescription
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// 登录过程中的可变状态（2FA 弹窗、进度、错误）.
/// Swift 6：本类是登录页的 UI 状态对象，只在主线程读写 → 标 `@MainActor` 是语义正确的隔离，
/// 同时让 `ctrl` 成为 Sendable，verificationHandler 的 @Sendable 闭包才能捕获它.
@MainActor
final class AppleLoginController: ObservableObject {
    @Published var isAuthenticating = false
    @Published var authError: String?
    @Published var showTwoFactorAlert = false
    @Published var twoFactorCode = ""
    var twoFactorReply: ((String?) -> Void)?
}

/// 登录诊断日志（查看 / 复制 / 分享 / 清空）.
///
/// 排版走共享的 `LogConsoleView`（逐行 `Text` + 行间 `Divider` + 自动滚底 + 复制带元信息头）——
/// 此前是**一整块 `Text`**，长日志糊成一坨。
struct LoginLogView: View {
    /// 只显示这些分类的日志（板块隔离）。
    ///
    /// `nil` = 全量（不按分类过滤）——**只保留给将来的「导出全部日志」**。
    /// ⚠️ **任何 UI 入口都不许再传 nil**：`RootView` 曾经用无参 `LoginLogView()` 进来，
    /// `nil` 会走不过滤的全量读取，于是商店 / 证书 / 侧载各板块的日志全串到这一页（用户实测指正）。
    var categories: [LoginLogger.Category]? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []

    var body: some View {
        // 本页由 `.sheet` 弹出，**必须自带导航容器** —— 否则 `LogConsoleView` 的
        // `navigationTitle` 与工具栏（清除/复制/分享/完成）没有导航栏可挂，整条工具栏都不会出现。
        NavigationStack {
            LogConsoleView(
                lines: lines,
                title: "登录诊断日志",
                onClear: {
                    LoginLogger.shared.clear()
                    refresh()
                },
                // 本页是 `.sheet` 弹出来的 → 需要「完成」按钮关闭（3105 同款）
                onDone: { dismiss() },
                clearConfirmTitle: "确定清空登录日志？"
            )
            .task {
                refresh()
                // 2s 轮询：登录/认证握手过程中能实时看到每一步
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { break }
                    refresh()
                }
            }
        }
    }

    /// 取日志行。
    /// - `categories != nil` → 只取该板块（`recentLines(_:categories:)`，逐行数组）；
    /// - `categories == nil` → 全量内存行（`recentLines(_:)`）—— 注意**不读日志文件**，
    ///   所以这里和旧的 `logText(categories: nil)`（走 `fullLog()` 会读文件）语义不同，
    ///   但 `nil` 现在没有 UI 入口，只影响将来的导出功能。
    private func refresh() {
        let fresh: [String]
        if let categories {
            fresh = LoginLogger.shared.recentLines(LogConsoleView.maxRenderedLines, categories: categories)
        } else {
            fresh = LoginLogger.shared.recentLines(LogConsoleView.maxRenderedLines)
        }
        // 轮询每 2s 重跑一次；内容没变就不重新赋值（避免白触发 body 重算）
        guard fresh != lines else { return }
        lines = fresh
    }
}
