import SwiftUI

/// 添加 App Store 账户（邮箱 + 密码 + 可选 2FA 验证码）。
struct AddAccountSheet: View {
    let onAdded: (AppStoreAccount) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Apple ID 邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                    TextField("验证码（如已收到 2FA）", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("账户信息")
                } footer: {
                    Text("若账户开启双重认证，先空着点登录，收到验证码后再填一次同密码重试。")
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

    private func login() {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        let email = self.email
        let password = self.password
        let code = self.code
        Task {
            LoginLogger.shared.log("App Store 下载：手动添加账户开始认证 \(email)（含验证码：\(code.isEmpty ? "否" : "是")）")
            do {
                let account = try await Authenticator.authenticate(
                    email: email,
                    password: password,
                    code: code
                )
                await MainActor.run {
                    busy = false
                    onAdded(account)
                    dismiss()
                }
                LoginLogger.shared.log("App Store 下载：手动添加账户认证成功，store=\(account.store)")
            } catch {
                await MainActor.run {
                    busy = false
                    errorMessage = "登录失败：\(error.localizedDescription)"
                }
                LoginLogger.shared.log("App Store 下载：手动添加账户认证失败 - \(error.localizedDescription)")
            }
        }
    }
}
