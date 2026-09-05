import SwiftUI

/// 搜索 App Store 应用并下载 IPA（含历史版本选择）.
///
/// 下载链路：账户登录 → 搜索/查询 → 免费入库（purchase）→ 取下载地址
/// （downloadURL + sinf）→ 下载 IPA → 注入 sinf 签名 → 交给「IPA 安装」.
struct AppStoreSearchView: View {
    let email: String

    @State private var keyword = ""
    @State private var results: [Software] = []
    @State private var searching = false
    @State private var busyEmail: String?
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var downloaded: [String] = []
    @State private var toast: String?

    private let store = AppStoreDownloadStore.shared

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("应用名称 / Bundle ID", text: $keyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        search()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(keyword.isEmpty || searching)
                }
            } header: {
                Text("搜索")
            } footer: {
                Text("当前账户：\(email).下载前会自动把免费应用入库（App Store 官方流程）.")
            }

            if searching {
                Section { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("搜索中…") } }
            }

            Section {
                if results.isEmpty {
                    Text("暂无结果")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(results) { app in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text("\(app.bundleID) · v\(app.version)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                download(app)
                            } label: {
                                if busyEmail == app.bundleID {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("下载", systemImage: "arrow.down.circle")
                                        .font(.caption)
                                }
                            }
                            .disabled(busyEmail != nil)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.blue)
                        }
                    }
                }
            } header: {
                Text("结果")
            }

            if !downloaded.isEmpty {
                Section {
                    ForEach(downloaded, id: \.self) { name in
                        HStack(spacing: 10) {
                            Image(systemName: "app.badge.checkmark")
                                .foregroundColor(.blue)
                            Text(name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                sendToInstaller(name: name)
                            } label: {
                                Label("安装", systemImage: "arrow.right.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("已下载")
                } footer: {
                    Text("点「安装」跳转到「IPA 安装」，选在线安装即可（无需再次签名）.")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }

            if !status.isEmpty {
                Section {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("搜索下载")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
        .onAppear { reloadDownloaded() }
    }

    // MARK: - 操作

    private func search() {
        guard !keyword.isEmpty else { return }
        searching = true
        errorMessage = nil
        let term = keyword
        Task {
            do {
                guard var account = store.account(for: email) else {
                    await MainActor.run { searching = false; errorMessage = "未找到账户" }
                    return
                }
                let countryCode = Configuration.countryCode(for: account.store) ?? "US"
                let list = try await Searcher.search(term: term, countryCode: countryCode, limit: 20)
                await MainActor.run {
                    searching = false
                    results = list
                    if list.isEmpty { status = "没有找到匹配的应用" }
                }
            } catch {
                await MainActor.run {
                    searching = false
                    errorMessage = "搜索失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func download(_ app: Software) {
        busyEmail = app.bundleID
        errorMessage = nil
        status = "准备下载 \(app.name)…"
        Task {
            do {
                guard var account = store.account(for: email) else {
                    await MainActor.run { busyEmail = nil; errorMessage = "未找到账户" }
                    return
                }
                // 1) 免费应用入库（付费应用 ApplePackage 不支持）
                try await Purchase.purchase(account: &account, app: app)
                await MainActor.run { status = "已入库，获取下载地址…" }
                // 2) 取下载地址 + sinf
                let output = try await Download.download(account: &account, app: app)
                await MainActor.run { status = "下载 IPA…" }
                // 3) 下载 IPA 到本地
                guard let url = URL(string: output.downloadURL) else {
                    throw NSError(domain: "AppStore", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "下载地址无效"])
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                let fileName = "\(app.bundleID)-\(app.version).ipa"
                let target = AppStoreDownloadStore.shared.downloadsDirectory + "/" + fileName
                try data.write(to: URL(fileURLWithPath: target), options: .atomic)
                await MainActor.run { status = "注入 FairPlay 签名…" }
                // 4) 注入 sinf（缺它 IPA 装不上）
                try await SignatureInjector.inject(sinfs: output.sinfs, into: target)
                await MainActor.run {
                    busyEmail = nil
                    status = "下载完成：\(fileName)"
                    toast = "已下载 \(app.name)"
                    reloadDownloaded()
                }
            } catch {
                await MainActor.run {
                    busyEmail = nil
                    errorMessage = "下载失败：\(error.localizedDescription)"
                    status = ""
                }
            }
        }
    }

    private func sendToInstaller(name: String) {
        // 记录待安装文件，供「IPA 安装」页读取（同一 App 内共享目录）.
        UserDefaults.standard.set(name, forKey: "pendingIPAPath")
        toast = "已选择 \(name)，请到「更多 → IPA 安装」点在线安装"
    }

    private func reloadDownloaded() {
        let fm = FileManager.default
        downloaded = ((try? fm.contentsOfDirectory(atPath: AppStoreDownloadStore.shared.downloadsDirectory)) ?? [])
            .filter { $0.hasSuffix(".ipa") }
            .sorted()
    }
}
