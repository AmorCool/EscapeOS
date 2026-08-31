import SwiftUI

/// 添加 App Store 账户（邮箱 + 密码）。若账户开启双重认证，
/// 登录后会弹出「来自 <邮箱> 的 2FA 验证码」输入框，填完直接返回账户，
/// 不在账户信息里预填验证码。
struct AddAccountSheet: View {
    let onAdded: (AppStoreAccount) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var showTwoFactor = false
    @State private var twoFactorCode = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                // 与 AppStoreDownloadView 共用同一套 2FA 弹窗（审计 Q12 单一入口）。
                TwoFactorCodePrompt(
                    isPresented: $showTwoFactor,
                    code: $twoFactorCode,
                    email: email,
                    onVerify: verifyTwoFactor
                )
                Section {
                    TextField("Apple ID 邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("账户信息")
                } footer: {
                    Text("若账户开启双重认证，点登录后会弹出验证码输入框，按提示填入即可。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button {
                        login()
                    } label: {
                        if busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("登录中…")
                            }
                        } else {
                            Text("登录")
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("添加账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func login(code: String = "") {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        let email = self.email
        let password = self.password
        Task {
            LoginLogger.shared.log("App Store 下载：手动添加账户开始认证 \(email)（含验证码：\(code.isEmpty ? "否" : "是")）")
            do {
                let account = try await Authenticator.authenticate(
                    email: email,
                    password: password,
                    code: code,
                    anisetteProvider: { try await fetchFreshAppStoreAnisetteHeaders() }
                )
                await MainActor.run {
                    busy = false
                    onAdded(account)
                    dismiss()
                }
                LoginLogger.shared.log("App Store 下载：手动添加账户认证成功，store=\(account.store)")
            } catch {
                let desc = error.localizedDescription
                await MainActor.run {
                    busy = false
                    if desc.contains("Authentication requires verification code") {
                        twoFactorCode = ""
                        showTwoFactor = true
                    } else {
                        errorMessage = iTunesAuthErrorMessage(error)
                    }
                }
                LoginLogger.shared.log("App Store 下载：手动添加账户认证失败 - \(desc)")
            }
        }
    }

    private func verifyTwoFactor() {
        let code = twoFactorCode
        showTwoFactor = false
        twoFactorCode = ""
        login(code: code)
    }
}
