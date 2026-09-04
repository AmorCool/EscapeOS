import SwiftUI
import UniformTypeIdentifiers

/// 证书管理（汉化移植自 SideInstaller 的 CertsView）。
///
/// 列出并吊销 Apple ID 的 iOS 开发证书。纯开发者门户 API 调用，
/// 不涉及设备 / 配对 / 隧道，因此不依赖 LocalDevVPN 与本地网络权限。
struct CertificateView: View {
    @StateObject private var manager = CertificateManager.shared
    @StateObject private var settings = MemoryLimitSettings.shared
    /// v0.3.131：自动撤销开关/白名单（统一撤销接口的管控项）
    @StateObject private var certStore = DeveloperCertStore.shared
    @State private var showLogin = false
    /// 待确认吊销的证书。
    @State private var pendingRevoke: DeveloperCertificate?
    /// 批量选择模式。
    @State private var selecting = false
    @State private var selected: Set<String> = []
    /// 批量吊销确认。
    @State private var showBatchRevokeConfirm = false

    // v0.3.152 p12 导入（同源证书方案：导入主程序同款证书）
    @State private var showP12Picker = false
    @State private var showP12Password = false
    @State private var p12Password = ""
    @State private var pendingP12Data: Data?
    @State private var p12Message: String?
    // v0.3.155 删除已导入证书（LC 同款）
    @State private var showRemoveCertConfirm = false

    var body: some View {
        List {
            headerSection
            // v0.3.131：自动撤销（统一撤销接口的管控开关）+ 白名单（仅一个）、（白名单与 SideStore/AltStore 标识的证书放行）遇 7460 情况使用
            Section(header: Text("自动撤销"), footer: Text("开启后，配额满会自动吊销旧证书.")) {
                Toggle("自动撤销证书", isOn: $certStore.autoRevokeEnabled)
                TextField("白名单", text: $certStore.revokeWhitelist)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            if !settings.isLoggedIn {
                notSignedInSection
            } else {
                teamSection
                // 团队栏自己已展示失败原因，这里只在团队加载成功后补全局错误，
                // 避免同一条消息在页面上出现两次。
                if let error = manager.lastError, manager.teamState == .loaded {
                    Section {
                        InfoActionCard(
                            icon: manager.lastErrorIsSessionExpired ? "person.badge.key.fill" : "exclamationmark.triangle.fill",
                            iconTint: manager.lastErrorIsSessionExpired ? .orange : .red,
                            title: manager.lastErrorIsSessionExpired ? "需要重新登录" : "出错了",
                            message: error
                        )
                    }
                }
                if manager.teamState == .loaded {
                    if manager.isWorking && manager.certs.isEmpty {
                        Section {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("正在加载证书…")
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else if manager.hasLoaded && manager.certs.isEmpty {
                        emptySection
                    } else if !manager.certs.isEmpty {
                        Section {
                            ForEach(manager.certs) { cert in
                                certRow(cert)
                                    // 左划：加入白名单（未在白名单时）
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        whitelistAddAction(cert)
                                    }
                                    // 右划：移出白名单（在白名单时）
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        whitelistRemoveAction(cert)
                                    }
                            }
                        } header: {
                            Text("\(manager.certs.count) 个证书")
                        }
                    }
                }
            }
            // v0.3.157：本地签名证书（p12）独立分组——登录与否都显示，与 Apple 侧证书列表区分
            localSigningSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("证书管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if settings.isLoggedIn && !manager.certs.isEmpty {
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
                } else if settings.isLoggedIn {
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
            p12ImportFooter
        }
        .onChange(of: showP12Picker) { shown in
            guard shown else { return }
            SharedDocumentPicker.present(allowedTypes: [.data]) { urls in
                guard let url = urls.first,
                      let data = try? Data(contentsOf: url) else {
                    p12Message = "✗ p12 文件读取失败"
                    return
                }
                pendingP12Data = data
                p12Password = ""
                showP12Password = true
            } onCancelled: {
                showP12Picker = false
            }
        }
        .alert("p12 密码", isPresented: $showP12Password) {
            TextField("导出时设置的密码", text: $p12Password)
            Button("导入") {
                guard let data = pendingP12Data else { return }
                let result = certStore.importP12(data: data, password: p12Password)
                p12Message = result.ok ? "✓ \(result.message)" : "✗ \(result.message)"
                pendingP12Data = nil
            }
            Button("取消", role: .cancel) { pendingP12Data = nil }
        } message: {
            Text("输入 p12 导出时设置的密码. 使用与主程序（LC/SideStore）相同的证书签名模块.")
        }
        .alert("删除本地签名证书？", isPresented: $showRemoveCertConfirm) {
            Button("删除", role: .destructive) {
                let result = certStore.removeLocalCert()
                p12Message = result.ok ? "✓ \(result.message)" : "✗ \(result.message)"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除本地签名用的证书文件（签名功能随之不可用），不会向 Apple 吊销证书. Apple 侧证书仍占账号名额，需要腾名额请用吊销功能.")
        }
        .sheet(isPresented: $showLogin) {
            AppleIDLoginSheet()
        }
        .onAppear {
            manager.autoLoad()
        }
        .onChange(of: settings.appleID) { _ in
            // 新登录 / 切换账号：清空旧团队的证书，重新拉团队列表.
            manager.reset()
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
            Text("将吊销已选的 \(selected.count) 张证书.用这些证书签名的应用会在所有设备上停止启动，且无法撤销.")
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
                Text("「\(cert.displayName)」将被吊销.已用该证书签名的应用会在所有设备上停止启动，且无法撤销.")
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
                        Text(settings.isLoggedIn
                             ? (manager.teamSummary ?? "已登录 Apple ID")
                             : "管理 Apple ID 的 iOS 开发证书（列出 / 吊销）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if !settings.isLoggedIn {
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

    // MARK: - 开发者团队（v0.2.112：对齐「增加内存限制」的团队栏）

    /// 团队选择器.与「增加内存限制」保持同一套展示语言：
    /// 加载中 → 进度；失败 → 红字 + 重试；成功 → Picker（单团队时补一行说明）.
    private var teamSection: some View {
        Section {
            switch manager.teamState {
            case .idle:
                // v0.2.120：`.idle` 以前和 `.loading` 渲染成同一个转圈，
                // 导致"压根没发起请求"被误认为"正在加载"，用户永远等不到结果.
                // 现在 `.idle` 明确显示未加载 + 给一个「加载」按钮.
                HStack {
                    Image(systemName: "exclamationmark.circle").foregroundColor(.orange)
                    Text("尚未加载团队")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("加载") { manager.loadTeams() }
                }
                .onAppear { manager.loadTeams() }
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在加载团队…")
                        .foregroundColor(.secondary)
                }
            case .failed(let message):
                HStack {
                    Text("加载失败")
                        .foregroundColor(.red)
                    Spacer()
                    Button("重试") { manager.loadTeams() }
                }
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .loaded:
                if manager.teams.isEmpty {
                    Text("账号下没有可用团队")
                        .foregroundColor(.secondary)
                } else {
                    Picker("选择团队", selection: $manager.selectedTeamID) {
                        ForEach(manager.teams) { team in
                            Text(team.name).tag(team.identifier)
                        }
                    }
                    .onChange(of: manager.selectedTeamID) { _ in
                        manager.loadCerts()
                    }
                    if manager.teams.count == 1, let only = manager.teams.first {
                        Text("\(only.name)（\(only.identifier)）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("开发者团队")
        }
    }

    // MARK: - 未登录

    /// 是否已全选（批量模式用）.
    private var allSelected: Bool {
        !manager.certs.isEmpty && selected.count == manager.certs.count
    }

    private var notSignedInSection: some View {
        Section {
            InfoActionCard(
                icon: "lock.fill",
                iconTint: .blue,
                title: "尚未登录",
                message: "登录 Apple ID 后即可查看账号下的开发证书并吊销失效证书.登录需要两步验证，凭据仅保存在本机钥匙串."
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
                message: "这个 Apple ID 下没有可吊销的 iOS 开发证书."
            )
        }
    }

    // MARK: - 证书行

    /// 是否命中白名单（序列号精确匹配）
    private func isWhitelisted(_ cert: DeveloperCertificate) -> Bool {
        !certStore.revokeWhitelist.isEmpty && cert.serialNumber == certStore.revokeWhitelist
    }

    // v0.3.152：底部安全区（现仅批量吊销栏；p12 已移至列表内独立分组 v0.3.157）
    @ViewBuilder
    private var p12ImportFooter: some View {
        VStack(spacing: 0) {
            if selecting {
                batchRevokeBar
            }
        }
        .background(.bar)
    }

    @ViewBuilder
    private func p12MessageText(_ msg: String) -> some View {
        let isOK = msg.hasPrefix("✓")
        Text(msg)
            .font(.caption)
            .foregroundStyle(isOK ? Color.green : Color.orange)
            .padding(.horizontal)
    }

    @ViewBuilder
    private var batchRevokeBar: some View {
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

    // v0.3.157：本地签名证书（p12）独立分组。作用：模块/文件真证书签名用的
    // 本地证书（导入的 p12 或登录自动签发），与上方 Apple 侧证书列表（吊销对象）区分。
    @ViewBuilder
    private var localSigningSection: some View {
        Section {
            if certStore.hasCert {
                Label(certStore.localCertSummary, systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundColor(.green)
            } else {
                Label("未设置本地签名证书", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            Button {
                showP12Picker = true
            } label: {
                Label("导入 p12 证书", systemImage: "square.and.arrow.down")
            }
            if certStore.hasCert {
                Button(role: .destructive) {
                    showRemoveCertConfirm = true
                } label: {
                    Label("删除已导入证书（仅本地）", systemImage: "trash")
                }
            }
            if let msg = p12Message {
                p12MessageText(msg)
            }
        } header: {
            Text("签名证书（p12）")
        } footer: {
            Text("用于模块/文件真证书签名。iOS 27 beta 起签名 identifier 需与主程序一致（已自动处理），证书本身 TeamID 匹配即可. 导入的 p12 会替换本地证书文件，不吊销 Apple 侧证书.")
        }
    }

    // v0.3.152：白名单 swipeActions 拆出（body type-check 超时修复）
    @ViewBuilder
    private func whitelistAddAction(_ cert: DeveloperCertificate) -> some View {
        if cert.serialNumber != certStore.revokeWhitelist {
            Button {
                certStore.revokeWhitelist = cert.serialNumber
            } label: {
                Label("加入白名单", systemImage: "checkmark.seal")
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func whitelistRemoveAction(_ cert: DeveloperCertificate) -> some View {
        if cert.serialNumber == certStore.revokeWhitelist {
            Button {
                certStore.revokeWhitelist = ""
            } label: {
                Label("移出白名单", systemImage: "xmark.seal")
            }
            .tint(.orange)
        }
    }

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
                    HStack(spacing: 6) {
                        Text(cert.displayName)
                            .font(.subheadline.weight(.semibold))
                        if isWhitelisted(cert) {
                            // v0.3.131：白名单胶囊标签（自动撤销时放行）
                            Text("白名单")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.15)))
                                .foregroundColor(.blue)

                        }
                    }
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
