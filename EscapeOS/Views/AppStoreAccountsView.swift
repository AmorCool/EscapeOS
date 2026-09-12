import SwiftUI

/// AppStore 账号管理 —— 多账号、切换当前下载账号、退出登录.
///
/// 职责：
///  · 已登录账号一览 + 点选「当前下载账号」+ 单个/全部「退出登录」；
///  · **添加账号**：走 Asspp 分叉的本地 SAP 登录（v0.3.323 起，不再用 anisette）；
///  · 账号体检：dsid / passwordToken / cookie 条数（这三样缺了 Apple 会当未登录，
///    下载就报 `MZFinance.NoAccount_message`）.
struct AppStoreAccountsView: View {

    @State private var accounts: [AppStoreAccount] = []
    @State private var current: String = ""
    @State private var confirmSignOutAll = false
    @State private var showAddAccount = false
    /// v0.3.332：单个账号「重登」（用已存凭据续期；Apple 要码时弹统一 2FA 面板并显示来源）
    @State private var reloginTarget: ReloginTarget?
    @State private var reloginBusyEmail: String?
    /// v0.3.344：长按账号 → 查已购列表（DMAP，只读）
    @State private var historyTarget: ReloginTarget?

    /// 2FA 面板的来源（sheet(item:) 需要 Identifiable）
    struct ReloginTarget: Identifiable { let id: String }

    private var store: AppStoreDownloadStore { .shared }

    var body: some View {
        List {
            currentSection
            accountsSection
            deviceSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AppStore 账号管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddAccount = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("退出全部") { confirmSignOutAll = true }
                    .disabled(accounts.isEmpty)
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheet { _ in
                reload()
            }
        }
        .sheet(item: $reloginTarget) { target in
            AddAccountSheet(reloginEmail: target.id) { _ in
                reload()
            }
        }
        .sheet(item: $historyTarget) { target in
            PurchaseHistoryView(email: target.id)
        }
        .confirmationDialog("退出所有 AppStore 账号？", isPresented: $confirmSignOutAll, titleVisibility: .visible) {
            Button("退出全部账号", role: .destructive) {
                store.signOutAll()
                reload()
                ToastCenter.shared.show("已退出全部账号")
            }
            Button("取消", role: .cancel) {}
        }
        .toastHost()
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
            Button {
                showAddAccount = true
            } label: {
                Label("添加 Apple ID", systemImage: "person.crop.circle.badge.plus")
                    .font(.subheadline.weight(.medium))
            }
            if accounts.isEmpty {
                Text("还没有登录任何 Apple ID").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(accounts, id: \.email) { a in
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "person.fill", tint: .blue, symbolSize: 16, frameSize: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.email).font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary).lineLimit(1)
                        Text(healthText(a)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    reloginCapsule(a)
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
                .contentShape(Rectangle())
                .onTapGesture {
                    store.select(email: a.email)
                    reload()
                    ToastCenter.shared.show("已切换到 \(a.email)")
                }
                .contextMenu {
                    Button {
                        historyTarget = ReloginTarget(id: a.email)
                    } label: {
                        Label("查已购列表", systemImage: "list.bullet.rectangle.portrait")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.signOut(email: a.email)
                        reload()
                        ToastCenter.shared.show("已退出 \(a.email)")
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        } header: {
            Text("已登录账号（\(accounts.count)）")
        } footer: {
            Text("点账号 = 设为当前下载账号；长按 = 查已购列表").font(.caption2)
        }
    }

    /// 「重登」胶囊：用已存凭据续期；Apple 要验证码时弹统一 2FA 面板
    @ViewBuilder
    private func reloginCapsule(_ a: AppStoreAccount) -> some View {
        Button {
            Task { await relogin(a) }
        } label: {
            Group {
                if reloginBusyEmail == a.email {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("重登").font(.caption.weight(.medium))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.blue.opacity(0.12), in: Capsule())
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .disabled(reloginBusyEmail != nil)
    }

    /// 先静默重登（多数情况免验证码）；Apple 要码则改弹 2FA 面板并带上来源邮箱
    private func relogin(_ a: AppStoreAccount) async {
        reloginBusyEmail = a.email
        defer { reloginBusyEmail = nil }
        do {
            let account = try await AppleIDSignInService.rotate(email: a.email)
            reload()
            ToastCenter.shared.show("已重登 \(account.email)")
        } catch let error as StoreAuthenticationError where error.needsCode {
            reloginTarget = ReloginTarget(id: a.email)
        } catch {
            ToastCenter.shared.show("重登失败：\(error.localizedDescription)")
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
                ToastCenter.shared.show("已重置设备标识")
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
            Text("设备标识（guid）是下载请求携带的身份；异常时可重置后重新登录下载。")
                .font(.caption2)
        }
    }

    // MARK: - 数据

    private func reload() {
        accounts = store.accounts
        current = store.selectedAccount?.email ?? ""
    }
}
