import SwiftUI
import UniformTypeIdentifiers

/// Entry point for the "增加内存限制" feature ported from GetMoreRam.
/// Currently manages the Apple ID account and Anisette server settings;
/// the actual Apple Developer API patch will be wired in a follow-up
/// once the StosSign engine is integrated into the Theos build.
struct IncreaseMemoryView: View {
    @StateObject private var settings = MemoryLimitSettings.shared
    @State private var showSignIn = false
    @State private var showNotReadyAlert = false
    @State private var showMissingAccountAlert = false

    var body: some View {
        List {
            accountSection
            anisetteSection
            actionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("增加内存限制")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSignIn) {
            MemoryLimitSignInSheet()
        }
        .alert("尚未登录", isPresented: $showMissingAccountAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请先登录 Apple ID 并选择 Anisette 服务器。")
        }
        .alert("功能未就绪", isPresented: $showNotReadyAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("Apple Developer API 调用尚未接入。请先在此配置账户与服务器，后续版本将完成开启逻辑。")
        }
    }

    private var accountSection: some View {
        Section(header: Text("Apple ID 账户")) {
            if settings.isLoggedIn {
                HStack {
                    Text("账号")
                    Spacer()
                    Text(settings.appleIDMasked)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    Text("Team ID")
                    Spacer()
                    Text(settings.teamIDMasked)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Button("退出登录", role: .destructive) {
                    settings.signOut()
                }
            } else {
                Button("登录 Apple ID") {
                    showSignIn = true
                }
            }
        }
    }

    private var anisetteSection: some View {
        Section(header: Text("Anisette 服务器")) {
            HStack {
                Text("当前服务器")
                Spacer()
                Text(host(from: settings.anisetteServer))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text("在「更多 → 设置」里可以切换 SideStore / StikStore 等备用服务器。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var actionSection: some View {
        Section(header: Text("操作"), footer: Text("开启后需要重新安装对应 App 才能使 INCREASED_MEMORY_LIMIT 能力生效。")) {
            Button {
                if !settings.isLoggedIn {
                    showMissingAccountAlert = true
                } else {
                    showNotReadyAlert = true
                }
            } label: {
                HStack {
                    Image(systemName: "memorychip")
                    Text("开启增加内存限制")
                }
            }
            .disabled(!settings.isLoggedIn)
        }
    }

    private func host(from urlString: String) -> String {
        urlString.replacingOccurrences(of: "https://", with: "")
                 .replacingOccurrences(of: "http://", with: "")
    }
}

// MARK: - Sign-in / SideStore import sheet

struct MemoryLimitSignInSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var teamID = ""
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

                Section(header: Text("Team ID"), footer: Text("登录成功后可在 Apple Developer 网站的 Membership 页面查看。也可先留空，后续再补。")) {
                    TextField("例如 8ABCD12345", text: $teamID)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                }

                Section {
                    Button("保存账户") {
                        MemoryLimitSettings.shared.signIn(
                            email: email,
                            password: password,
                            teamID: teamID
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
            .navigationTitle("登录")
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
