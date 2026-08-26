import SwiftUI
import UniformTypeIdentifiers

/// Reusable Apple ID sign-in sheet used by Settings > Apple ID 账户.
/// Extracted from GetMoreRam's login modal; currently stores credentials
/// locally. The actual StosSign/AppleAPI authentication engine (with 2FA)
/// will be wired in a follow-up.
struct AppleIDLoginSheet: View {
    @Environment(\.dismiss) private var dismiss

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
                    Button("保存账户") {
                        MemoryLimitSettings.shared.signIn(
                            email: email,
                            password: password
                        )
                        dismiss()
                    }
                    .disabled(email.isEmpty || password.isEmpty)
                }

                Section(header: Text("SideStore"), footer: Text("从 SideStore 设置中导出账户 JSON，可免去手动输入账号密码。")) {
                    Button("导入 SideStore 账户文件") {
                        showImporter = true
                    }
                }
            }
            .navigationTitle("登录 Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert("导入失败", isPresented: .constant(importError != nil)) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                throw MemoryLimitError.missingField
            }

            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart { url.stopAccessingSecurityScopedResource() }
            }

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
