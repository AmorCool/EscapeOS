import SwiftUI

/// Apple ID 登录（v0.3.323：Asspp 分叉的**本地 SAP 签名**方案重写）。
///
/// 与 v0.3.312 删掉的那版的最大区别：**不需要 anisette、不需要任何第三方服务器**。
/// 登录请求由本地 Unicorn TCI 解释执行 Apple 自己的 x86 CommerceKit 来签名
/// （`SAPAssets/` 由构建期脚本放进 bundle），因此也不会被 Apple 认证边缘按
/// 第三方客户端标识软拒绝。
///
/// 交互：邮箱 + 密码 → 若开了双重认证，Apple 会返回「需要验证码」，此时展开验证码输入框，
/// 同一份凭据带上验证码重试一次即可（SAP 协议本身如此，不是失败重试）。
struct AddAccountSheet: View {

    /// 重登模式：填了邮箱就只补验证码，账号/密码用已保存的（标题与副标题显示「来源」）
    var reloginEmail: String? = nil

    /// 登录成功回调（账号已写入 AppStoreDownloadStore，并成为当前下载账号）
    var onSuccess: (AppStoreAccount) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needCode = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var stage = ""

    private var isRelogin: Bool { !(reloginEmail ?? "").isEmpty }
    private var sourceEmail: String { reloginEmail ?? email }
    private var assetsReady: Bool { AppleIDSignInService.assetsReady }
    private var canSubmit: Bool {
        let base = !busy && email.contains("@") && !password.isEmpty
        return isRelogin ? (!busy && !code.isEmpty) : (base && (!needCode || !code.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Form {
                if isRelogin {
                    Section("来源") {
                        Text(sourceEmail).font(.subheadline)
                    }
                }
                Section {
                    if !isRelogin {
                        TextField("Apple ID（邮箱）", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                    }
                    if needCode || isRelogin {
                        TextField("双重认证验证码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                } header: {
                    Text("账号")
                } footer: {
                    if isRelogin || needCode {
                        Text("验证码已发送到受信任设备").font(.caption2)
                    }
                }

                if !assetsReady {
                    Section {
                        Label("SAP 资产缺失，登录会失败", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy {
                                ProgressView().controlSize(.small)
                                Text(stage.isEmpty ? "登录中…" : stage)
                            } else {
                                Text(isRelogin ? "重登" : (needCode ? "带验证码登录" : "登录"))
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle(isRelogin ? "重新登录 · 双重认证" : "登录 Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .onAppear {
            if isRelogin { needCode = true }
        }
    }

    private func submit() async {
        if isRelogin { await relogin() } else { await signIn() }
    }

    /// 重登：只用已保存的凭据 + 验证码
    private func relogin() async {
        busy = true
        errorText = nil
        stage = "连接 Apple…"
        defer { busy = false; stage = "" }
        LoginLogger.shared.log("[SAP] 重新登录 \(sourceEmail)", category: .appStore)
        do {
            let account = try await AppleIDSignInService.rotate(
                email: sourceEmail, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            ToastCenter.shared.show("已重登 \(account.email)")
            onSuccess(account)
            dismiss()
        } catch let error as StoreAuthenticationError {
            LoginLogger.shared.log("[SAP] 重登失败：\(error.localizedDescription)", category: .appStore)
            errorText = error.localizedDescription
        } catch {
            LoginLogger.shared.log("[SAP] 重登失败：\(error.localizedDescription)", category: .appStore)
            errorText = error.localizedDescription
        }
    }

    private func signIn() async {
        busy = true
        errorText = nil
        stage = "连接 Apple…"
        defer { busy = false; stage = "" }
        LoginLogger.shared.log("[SAP] 开始登录 \(email)", category: .appStore)
        do {
            let account = try await AppleIDSignInService.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                code: code) { line in
                    LoginLogger.shared.log("[SAP] \(line)", category: .appStore)
                }
            LoginLogger.shared.log("[SAP] 登录成功：dsid \(account.directoryServicesIdentifier.isEmpty ? "空" : "OK")",
                                   category: .appStore)
            onSuccess(account)
            ToastCenter.shared.show("已登录 \(account.email)")
            dismiss()
        } catch let error as StoreAuthenticationError {
            LoginLogger.shared.log("[SAP] 失败：\(error.localizedDescription)", category: .appStore)
            errorText = error.localizedDescription
            // 需要验证码 → 展开输入框（同一份凭据再走一次，不是"重试")
            if error.needsCode {
                needCode = true
                code = ""
            }
        } catch {
            LoginLogger.shared.log("[SAP] 失败：\(error.localizedDescription)", category: .appStore)
            errorText = error.localizedDescription
        }
    }
}
