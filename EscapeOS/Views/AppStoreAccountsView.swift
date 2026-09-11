import SwiftUI

/// v0.3.308：AppStore 账号管理 —— 多账号、批量登录、退出登录.
///
/// 之前的问题：商店里只能看到一个账号（`accounts.first`），无法切换、无法退出、
/// 也无法一次登录多个账号。这个页面补齐三件事：
///  · 已登录账号一览 + 点选「当前下载账号」+ 单个/全部「退出登录」；
///  · **批量登录**：一行一个账号（`邮箱 密码` 或 `邮箱----密码`），逐条走 Go 栈登录；
///  · 账号体检：dsid / passwordToken / cookie 条数（这三样缺了 Apple 会当未登录，
///    下载就报 `MZFinance.NoAccount_message`）.
struct AppStoreAccountsView: View {

    @State private var accounts: [AppStoreAccount] = []
    @State private var current: String = ""
    @State private var batchText = "邮箱 密码（每行一个账号）"
    @State private var busy = false
    @State private var progressText = ""
    @State private var results: [AppStoreDownloadStore.BatchResult] = []
    @State private var confirmSignOutAll = false
    @State private var toast: String?

    private var store: AppStoreDownloadStore { .shared }

    var body: some View {
        List {
            currentSection
            accountsSection
            deviceSection
            batchSection
            if !results.isEmpty { resultsSection }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AppStore 账号管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("退出全部") { confirmSignOutAll = true }
                    .disabled(accounts.isEmpty)
            }
        }
        .confirmationDialog("退出所有 AppStore 账号？", isPresented: $confirmSignOutAll, titleVisibility: .visible) {
            Button("退出全部账号", role: .destructive) {
                store.signOutAll()
                reload()
                toast = "已退出全部账号"
            }
            Button("取消", role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
            }
        }
        .onAppear { reload() }
    }

    // MARK: - 当前账号

    @ViewBuilder
    private var currentSection: some View {
        Section("当前下载账号") {
            if current.isEmpty {
                Text("未选择（没有已登录账号）").font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "person.crop.circle.fill", tint: .green,
                               symbolSize: 18, frameSize: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current).font(.subheadline.weight(.medium)).lineLimit(1)
                        if let a = store.account(for: current) {
                            Text(healthText(a)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// dsid / passwordToken / cookie —— 缺任一项 Apple 就会把下载当未登录
    private func healthText(_ a: AppStoreAccount) -> String {
        var parts: [String] = ["store \(a.store)"]
        parts.append(a.directoryServicesIdentifier.isEmpty ? "缺 dsid" : "dsid OK")
        parts.append(a.passwordToken.isEmpty ? "缺 token" : "token OK")
        parts.append("cookie \(a.cookie.count)")
        return parts.joined(separator: " · ")
    }

    /// 失效账号（缺 dsid/token）不能用于下载，需要在 UI 上明确标出来
    private func needsRelogin(_ a: AppStoreAccount) -> Bool {
        !AppStoreDownloadStore.isUsable(a)
    }

    // MARK: - 账号列表

    @ViewBuilder
    private var accountsSection: some View {
        Section {
            if accounts.isEmpty {
                Text("还没有登录任何 Apple ID").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(accounts, id: \.email) { a in
                Button {
                    store.select(email: a.email)
                    reload()
                    toast = "已切换到 \(a.email)"
                } label: {
                    HStack(spacing: 12) {
                        AppRowIcon(systemName: "person.fill", tint: .blue, symbolSize: 16, frameSize: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.email).font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary).lineLimit(1)
                            Text(healthText(a)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if needsRelogin(a) {
                            Text("需重新登录")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        } else if a.email == current {
                            Image(systemName: "checkmark").foregroundStyle(.green).font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.signOut(email: a.email)
                        reload()
                        toast = "已退出 \(a.email)"
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        } header: {
            Text("已登录账号（\(accounts.count)）")
        } footer: {
            Text("点账号即设为「当前下载账号」；左滑可退出该账号。下载时使用的是当前账号。")
                .font(.caption2)
        }
    }

    // MARK: - 设备与认证（Apple 认证边缘软拒绝时的自救入口）

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            HStack {
                Text("设备标识（guid）").font(.subheadline)
                Spacer()
                Text(String(Configuration.deviceIdentifier.prefix(14)) + "…")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                store.resetDeviceIdentifier()
                reload()
                toast = "已重置设备标识，请重新登录"
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("重置设备标识")
                }
                .font(.subheadline.weight(.medium))
            }
        } header: {
            Text("设备与认证")
        } footer: {
            Text("登录被 Apple 边缘拒绝（HTTP 404/503/204 之类的软拒绝）时，可重置设备标识后再试。")
                .font(.caption2)
        }
    }

    // MARK: - 批量登录

    @ViewBuilder
    private var batchSection: some View {
        Section {
            TextEditor(text: $batchText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 90)
                .disabled(busy)
            Button {
                startBatchLogin()
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? progressText : "开始批量登录")
                        .font(.subheadline.weight(.medium))
                }
            }
            .disabled(busy)
        } header: {
            Text("批量登录")
        } footer: {
            Text("每行一个账号：`邮箱 密码` 或 `邮箱----密码`。开启双重认证的账号需要验证码，"
                 + "批量登录会失败并列出原因 —— 这类账号请到「AppStore 下载」页单独登录（可填验证码）。")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        Section("批量登录结果") {
            ForEach(results) { r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(r.ok ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.email).font(.footnote.weight(.medium))
                        Text(r.message).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 数据

    private func reload() {
        accounts = store.accounts
        current = store.selectedAccount?.email ?? ""
    }

    /// 解析批量输入：每行「邮箱 密码」或「邮箱----密码」
    private func parseBatch(_ text: String) -> [(String, String)] {
        text.components(separatedBy: .newlines).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.contains(" ") || t.contains("----") else { return nil }
            if let r = t.range(of: "----") {
                let email = String(t[t.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let pw = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                return email.isEmpty || pw.isEmpty ? nil : (email, pw)
            }
            let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let pw = parts[1].trimmingCharacters(in: .whitespaces)
            return pw.isEmpty ? nil : (parts[0], pw)
        }
    }

    private func startBatchLogin() {
        let list = parseBatch(batchText)
        guard !list.isEmpty else {
            toast = "没有解析到账号，格式：邮箱 密码（每行一个）"
            return
        }
        busy = true
        results = []
        LoginLogger.shared.log("[AppStore] 开始批量登录 \(list.count) 个账号", category: .appStore)

        Task.detached(priority: .userInitiated) {
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path
            var done: [AppStoreDownloadStore.BatchResult] = []
            for (idx, item) in list.enumerated() {
                await MainActor.run {
                    self.progressText = "登录中 \(idx + 1)/\(list.count)…"
                }
                do {
                    let account = try GoAppStoreAuth.login(
                        email: item.0,
                        password: item.1,
                        code: "",
                        deviceIdentifier: Configuration.deviceIdentifier,
                        cacheDir: cacheDir
                    )
                    await MainActor.run { AppStoreDownloadStore.shared.add(account) }
                    LoginLogger.shared.log("[AppStore] 批量登录成功 \(item.0)", category: .appStore)
                    done.append(.init(email: item.0, ok: true,
                                      message: "登录成功（store \(account.store)）"))
                } catch {
                    let desc = error.localizedDescription
                    let need2FA = desc.contains("verification code")
                    LoginLogger.shared.log("[AppStore] 批量登录失败 \(item.0)：\(desc)", category: .appStore)
                    done.append(.init(email: item.0, ok: false,
                                      message: need2FA ? "需要双重认证验证码 → 请到「AppStore 下载」单独登录"
                                                       : desc))
                }
            }
            let finished = done
            await MainActor.run {
                self.results = finished
                self.busy = false
                self.progressText = ""
                self.reload()
                self.toast = "批量登录完成：成功 \(finished.filter(\.ok).count)/\(finished.count)"
            }
        }
    }
}
