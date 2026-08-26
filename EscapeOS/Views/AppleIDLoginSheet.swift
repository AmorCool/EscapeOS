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
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Apple ID")) {
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("密码", text: $password)
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
        do {
            let anisette = try await AnisetteProvider.shared.getAnisetteData()
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
            await MainActor.run {
                ctrl.isAuthenticating = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                ctrl.isAuthenticating = false
                ctrl.authError = (error as? AppleAPIError)?.errorDescription ?? error.localizedDescription
            }
        }
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
