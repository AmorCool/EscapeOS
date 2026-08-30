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
struct AppStoreDownloadView: View {
    @State private var accounts: [AppStoreAccount] = []
    @State private var selectedEmail: String = ""
    @State private var showAddAccount = false
    @State private var busy = false
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var toast: String?

    private let store = AppStoreDownloadStore.shared

    var body: some View {
        List {
            accountSection
            downloadSection
            if let errorMessage { errorSection }
            statusSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Store 下载")
        .navigationBarTitleDisplayMode(.inline)
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
            Button {
                showAddAccount = true
            } label: {
                Label("添加 App Store 账户", systemImage: "person.badge.plus")
            }
            .foregroundColor(.blue)
        } header: {
            Text("账户")
        } footer: {
            Text("登录的是 App Store（不是开发者后台），用于下载你已购买 / 免费入库的应用。凭据只保存在本机。")
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

    // MARK: - 操作

    private func reload() {
        accounts = store.accounts
        if selectedEmail.isEmpty { selectedEmail = accounts.first?.email ?? "" }
    }
}
