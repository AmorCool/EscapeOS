import SwiftUI
import UniformTypeIdentifiers

/// 登录 Apple ID 的弹窗。
/// 调用本地自带的 Apple 认证引擎（SRP-6a + Anisette v3）完成真实登录，
/// 而非仅保存凭据。需要两步验证时会弹出验证码输入框。
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
                    Text("开启后，登录成功的账户会保存在「最近登录」列表中，之后可从下拉菜单一键登录；未开启则不记录。")
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

                Section(header: Text("SideStore"), footer: Text("从 SideStore 设置中导出账户 JSON，可免去手动输入账号密码，并直接带入设备认证所需的 adi.pb 与本地标识。")) {
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
                LoginLogView()
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
                Text("Apple 已向你的受信任设备或短信发送验证码，请输入以完成登录。")
            }
        }
    }

    @MainActor
    private func signIn() async {
        ctrl.isAuthenticating = true
        ctrl.authError = nil
        LoginLogger.shared.log("▶ 用户点击登录: \(email.lowercased())")
        do {
            let anisette = try await AnisetteProvider.shared.getAnisetteData()
            LoginLogger.shared.log("✓ Anisette 获取成功，进入 GrandSlam 握手")
            let (account, session) = try await AppleAuthenticator.authenticate(
                appleID: email,
                password: password,
                anisetteData: anisette
            ) { reply in
                DispatchQueue.main.async {
                    ctrl.twoFactorCode = ""
                    ctrl.twoFactorReply = reply
                    ctrl.showTwoFactorAlert = true
                }
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

    /// 从「最近登录」选择一个账户：回填邮箱与密码并立即登录。
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

/// 登录过程中的可变状态（2FA 弹窗、进度、错误）。
final class AppleLoginController: ObservableObject {
    @Published var isAuthenticating = false
    @Published var authError: String?
    @Published var showTwoFactorAlert = false
    @Published var twoFactorCode = ""
    var twoFactorReply: ((String?) -> Void)?
}

/// 登录诊断日志查看与导出（查看 / 复制 / 导出分享 / 清空）。
struct LoginLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showShare = false
    @State private var showClearConfirm = false
    @State private var refreshTick = 0

    private var logText: String {
        _ = refreshTick
        return LoginLogger.shared.fullLog().isEmpty ? "（暂无日志，请先尝试一次登录）" : LoginLogger.shared.fullLog()
    }

    var body: some View {
        NavigationView {
            ScrollView {
                Text(logText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("登录诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button {
                            showClearConfirm = true
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .disabled(LoginLogger.shared.fullLog().isEmpty)
                        Button("复制") {
                            UIPasteboard.general.string = logText
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                        .disabled(LoginLogger.shared.fullLog().isEmpty)
                    }
                }
            }
            .confirmationDialog("确定清空登录日志？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空日志", role: .destructive) {
                    LoginLogger.shared.clear()
                    refreshTick += 1
                }
                Button("取消", role: .cancel) {}
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showShare = true
                } label: {
                    Label("导出分享日志", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding()
                .disabled(LoginLogger.shared.fullLog().isEmpty)
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [logText])
            }
            .alert("已复制", isPresented: $copied) {
                Button("好", role: .cancel) {}
            } message: {
                Text("日志已复制到剪贴板，可直接粘贴发给开发者。")
            }
        }
    }
}
