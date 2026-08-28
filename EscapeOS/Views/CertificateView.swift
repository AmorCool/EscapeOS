import SwiftUI

/// 证书管理（汉化移植自 SideInstaller 的 CertsView）。
///
/// 列出并吊销 Apple ID 的 iOS 开发证书。纯开发者门户 API 调用，
/// 不涉及设备 / 配对 / 隧道，因此不依赖 LocalDevVPN 与本地网络权限。
struct CertificateView: View {
    @StateObject private var manager = CertificateManager.shared
    @State private var showLogin = false
    /// 待确认吊销的证书。
    @State private var pendingRevoke: DeveloperCertificate?
    /// 批量选择模式。
    @State private var selecting = false
    @State private var selected: Set<String> = []
    /// 批量吊销确认。
    @State private var showBatchRevokeConfirm = false

    var body: some View {
        List {
            headerSection
            if !manager.isSignedIn {
                notSignedInSection
            } else {
                if let error = manager.lastError {
                    Section {
                        InfoActionCard(
                            icon: "exclamationmark.triangle.fill",
                            iconTint: .red,
                            title: "出错了",
                            message: error
                        )
                    }
                }
                if manager.hasLoaded && manager.certs.isEmpty && !manager.isWorking {
                    emptySection
                } else if !manager.certs.isEmpty {
                    Section {
                        ForEach(manager.certs) { cert in
                            certRow(cert)
                        }
                    } header: {
                        Text("\(manager.certs.count) 个证书")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("证书管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if manager.isSignedIn && !manager.certs.isEmpty {
                    Button(selecting ? "取消" : "选择") {
                        selecting.toggle()
                        if !selecting { selected.removeAll() }
                    }
                    .disabled(manager.isWorking)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if selecting {
                    Button(allSelected ? "取消全选" : "全选") {
                        if allSelected {
                            selected.removeAll()
                        } else {
                            selected = Set(manager.certs.map(\.id))
                        }
                    }
                    .disabled(manager.isWorking)
                } else if manager.isSignedIn {
                    Button {
                        manager.loadCerts()
                    } label: {
                        if manager.isWorking {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(manager.isWorking)
                } else {
                    Button("登录") { showLogin = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Text("已选 \(selected.count) 项")
                        .font(.subheadline)
                    Spacer()
                    Button("吊销", role: .destructive) {
                        showBatchRevokeConfirm = true
                    }
                    .disabled(selected.isEmpty || manager.isWorking)
                }
                .padding()
                .background(.bar)
            }
        }
        .sheet(isPresented: $showLogin) {
            AppleIDLoginSheet()
        }
        .onAppear {
            manager.autoLoad()
        }
        .alert("吊销所选证书？", isPresented: $showBatchRevokeConfirm) {
            Button("吊销", role: .destructive) {
                let targets = manager.certs.filter { selected.contains($0.id) }
                manager.batchRevoke(targets)
                selected.removeAll()
                selecting = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将吊销已选的 \(selected.count) 张证书。用这些证书签名的应用会在所有设备上停止启动，且无法撤销。")
        }
        .alert("吊销这张证书？", isPresented: Binding(
            get: { pendingRevoke != nil },
            set: { if !$0 { pendingRevoke = nil } }
        )) {
            Button("吊销", role: .destructive) {
                if let cert = pendingRevoke { manager.revoke(cert) }
                pendingRevoke = nil
            }
            Button("取消", role: .cancel) { pendingRevoke = nil }
        } message: {
            if let cert = pendingRevoke {
                Text("「\(cert.displayName)」将被吊销。已用该证书签名的应用会在所有设备上停止启动，且无法撤销。")
            }
        }
    }

    // MARK: - 头部

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AppRowIcon(systemName: "checkmark.seal.fill", tint: .blue, symbolSize: 20, frameSize: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("证书管理")
                            .font(.headline)
                        Text(manager.isSignedIn
                             ? (manager.teamSummary ?? "已登录 Apple ID")
                             : "管理 Apple ID 的 iOS 开发证书（列出 / 吊销）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if !manager.isSignedIn {
                    Button {
                        showLogin = true
                    } label: {
                        HStack {
                            Image(systemName: "person.fill.badge.key")
                            Text("登录 Apple ID")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.blue)
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - 未登录

    /// 是否已全选（批量模式用）。
    private var allSelected: Bool {
        !manager.certs.isEmpty && selected.count == manager.certs.count
    }

    private var notSignedInSection: some View {
        Section {
            InfoActionCard(
                icon: "lock.fill",
                iconTint: .blue,
                title: "尚未登录",
                message: "登录 Apple ID 后即可查看账号下的开发证书并吊销失效证书。登录需要两步验证，凭据仅保存在本机钥匙串。"
            )
        }
    }

    // MARK: - 空状态

    private var emptySection: some View {
        Section {
            InfoActionCard(
                icon: "checkmark.seal",
                iconTint: .blue,
                title: "没有证书",
                message: "这个 Apple ID 下没有可吊销的 iOS 开发证书。"
            )
        }
    }

    // MARK: - 证书行

    private func certRow(_ cert: DeveloperCertificate) -> some View {
        let revoking = manager.revokingID == cert.id
        let isSelected = selected.contains(cert.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                        .onTapGesture {
                            if isSelected {
                                selected.remove(cert.id)
                            } else {
                                selected.insert(cert.id)
                            }
                        }
                        .padding(.top, 2)
                }
                Image(systemName: "seal.fill")
                    .font(.title3)
                    .foregroundStyle(cert.isExpired ? Color.orange : Color.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cert.displayName)
                        .font(.subheadline.weight(.semibold))
                    if let machine = cert.machineLabel {
                        Label(machine, systemImage: "desktopcomputer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if cert.isExpired {
                    Text("已过期")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selecting {
                    if isSelected {
                        selected.remove(cert.id)
                    } else {
                        selected.insert(cert.id)
                    }
                }
            }

            if cert.expiration != nil || !cert.serialNumber.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if let expiry = cert.expiration {
                        Label("到期 \(expiry.formatted(date: .abbreviated, time: .omitted))",
                              systemImage: "calendar")
                    }
                    if !cert.serialNumber.isEmpty {
                        Label(cert.serialNumber, systemImage: "number")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            if !selecting {
                Button(role: .destructive) {
                    pendingRevoke = cert
                } label: {
                    HStack(spacing: 6) {
                        if revoking {
                            ProgressView().controlSize(.small)
                            Text("吊销中")
                        } else {
                            Image(systemName: "trash")
                            Text("吊销")
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.regular)
                .disabled(revoking || manager.isWorking || manager.revokingID != nil)
            }
        }
        .padding(.vertical, 4)
    }
}
