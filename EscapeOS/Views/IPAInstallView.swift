import SwiftUI
import UniformTypeIdentifiers

/// IPA 侧载（汉化移植自 SideInstaller 的「安装」板块）。
///
/// 选择 IPA（本地导入 / URL 下载）→ 登录 Apple ID（含 2FA）→ 签名 →
/// 通过 LocalDevVPN 隧道安装到设备。导入走 SharedDocumentPicker 统一调用点
/// （LC/证书直装环境可靠）。
struct IPAInstallView: View {
    @StateObject private var service = IPAInstallService.shared

    // IPA 源
    @State private var showImporter = false
    @State private var ipaURL: URL?
    @State private var ipaLink = ""
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    /// 「已下载的 IPA」列表（Documents/Custom 目录）。
    @State private var savedIPAs: [SavedIPA] = []
    /// 待确认删除的 IPA。
    @State private var pendingDeleteIPA: SavedIPA?

    // Apple ID
    @State private var appleID = ""
    @State private var password = ""
    @State private var showPassword = false
    /// 是否已从「更多 → 设置」复用过凭据（避免重复触发自动登录）。
    @State private var didPrefillCredentials = false
    /// 正在用设置里保存的 Apple ID 自动登录。
    @State private var isAutoSigningIn = false

    // 2FA
    @State private var showTwoFactor = false
    @State private var twoFactorCode = ""
    @State private var twoFactorReply: ((String?) -> Void)?

    // 流程
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var step: Step = .idle
    @State private var installProgress: Double = 0

    /// 一个已下载/导入的 IPA 文件。
    private struct SavedIPA: Identifiable {
        let url: URL
        let name: String
        let size: Int64
        let modified: Date?
        var id: String { url.path }
    }

    /// IPA 统一存放目录（对齐 SideInstaller 的 IPALibrary.customDir）。
    private var customDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Custom", isDirectory: true)
    }

    private enum Step {
        case idle, signingIn, signing, installing, done
        var text: String? {
            switch self {
            case .idle: return nil
            case .signingIn: return "正在登录 Apple ID…"
            case .signing: return "正在签名 IPA…"
            case .installing: return "正在安装到设备…"
            case .done: return "安装完成"
            }
        }
    }

    private var pairingFileExists: Bool {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return false }
        return size > 0
    }

    private var ipaDisplayName: String {
        ipaURL?.lastPathComponent ?? ""
    }

    var body: some View {
        List {
            // 头部
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        AppRowIcon(systemName: "arrow.down.app.fill", tint: .blue, symbolSize: 20, frameSize: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("IPA 侧载")
                                .font(.headline)
                            Text("签名并安装 IPA 到设备（需 Apple ID + 配对文件 + LocalDevVPN）。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    if !pairingFileExists {
                        Label("未检测到配对文件，请先在「应用」页导入", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 6)
            }

            // IPA 源
            Section {
                Button {
                    showImporter = true
                } label: {
                    HStack {
                        Label(ipaURL == nil ? "导入 IPA 文件" : "重新导入 IPA 文件",
                              systemImage: "doc.badge.plus")
                        Spacer()
                        if ipaURL != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                .disabled(isRunning)

                if let url = ipaURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    TextField("或粘贴 IPA 直链（http/https）", text: $ipaLink)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        downloadIPA()
                    } label: {
                        if isDownloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("下载")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(ipaLink.isEmpty || isRunning || isDownloading)
                }
                if isDownloading {
                    ProgressView(value: downloadProgress)
                }
            } header: {
                Text("IPA")
            } footer: {
                Text("导入的 IPA 会先拷贝到应用沙盒（统一文件选择调用点），可离线签名安装。")
            }

            // 已下载的 IPA
            Section {
                if savedIPAs.isEmpty {
                    Text("暂无已下载的 IPA。导入或下载的 IPA 会保存在这里。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(savedIPAs) { item in
                        HStack(spacing: 12) {
                            AppRowIcon(systemName: "shippingbox.fill", tint: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 8) {
                                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                    if let modified = item.modified {
                                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            if ipaURL?.path == item.url.path {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 再次点击已选项 = 取消选择（ipaURL 置空，勾选消失）。
                            if ipaURL?.path == item.url.path {
                                ipaURL = nil
                            } else {
                                ipaURL = item.url
                            }
                            ipaLink = ""
                            errorMessage = nil
                            successMessage = nil
                        }
                    }
                    .onDelete { offsets in
                        if let idx = offsets.first {
                            pendingDeleteIPA = savedIPAs[idx]
                        }
                    }
                }
            } header: {
                Text("已下载的 IPA")
            } footer: {
                Text("点击选择为要安装的 IPA，再次点击取消选择；左滑删除。")
            }

            // Apple ID
            Section {
                if service.isSignedIn {
                    HStack {
                        Label(service.teamSummary ?? "已登录", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Spacer()
                        Button("退出") {
                            service.signOut()
                            appleID = ""
                            password = ""
                        }
                        .font(.subheadline)
                    }
                } else if isAutoSigningIn {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("正在用「设置」里的 Apple ID 自动登录…")
                                .font(.subheadline)
                            Text("如需两步验证，验证码弹窗会在此显示。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Apple ID 邮箱", text: $appleID)
                            } else {
                                SecureField("Apple ID 邮箱", text: $appleID)
                            }
                        }
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    }
                    HStack {
                        Group {
                            if showPassword {
                                TextField("密码", text: $password)
                            } else {
                                SecureField("密码", text: $password)
                            }
                        }
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Apple ID")
            } footer: {
                Text(service.isSignedIn
                     ? "签名会话已就绪。"
                     : "登录用于获取签名证书与描述文件；2FA 验证码在安装时弹出。")
            }

            // 流程状态
            if let stepText = step.text {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(stepText)
                            .font(.subheadline)
                        Spacer()
                        if step == .installing {
                            Text("\(Int(installProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if let error = errorMessage {
                Section {
                    InfoActionCard(
                        icon: "exclamationmark.triangle.fill",
                        iconTint: .red,
                        title: "出错了",
                        message: error
                    )
                }
            }
            if let success = successMessage {
                Section {
                    InfoActionCard(
                        icon: "checkmark.seal.fill",
                        iconTint: .green,
                        title: "完成",
                        message: success
                    )
                }
            }

            // 安装按钮
            Section {
                Button {
                    startInstall()
                } label: {
                    HStack {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        }
                        Text(isRunning ? "正在处理…" : "签名并安装")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)
                .disabled(isRunning || ipaURL == nil
                          || (!service.isSignedIn && (appleID.isEmpty || password.isEmpty)))
            } footer: {
                Text("需要 Apple ID 登录态（若未登录需填写上方凭据）、已导入 IPA、配对文件与 LocalDevVPN。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("IPA 侧载")
        .navigationBarTitleDisplayMode(.inline)
        .documentPicker(isPresented: $showImporter, allowedTypes: [UTType(filenameExtension: "ipa") ?? .data]) { urls in
            if let url = urls.first {
                importIPA(from: url)
            }
        }
        .onAppear {
            service.twoFactorPrompt = { reply in
                twoFactorCode = ""
                twoFactorReply = reply
                showTwoFactor = true
            }
            refreshSavedIPAs()
            // 复用「更多 → 设置」已保存的 Apple ID：自动登录（无需手动输入），
            // 失败才回退手动输入。
            if !didPrefillCredentials {
                didPrefillCredentials = true
                autoSignInWithSavedCredentials()
            }
        }
        .onDisappear {
            service.twoFactorPrompt = nil
        }
        .alert("删除已下载的 IPA？", isPresented: Binding(
            get: { pendingDeleteIPA != nil },
            set: { if !$0 { pendingDeleteIPA = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let item = pendingDeleteIPA {
                    deleteSavedIPA(item)
                }
                pendingDeleteIPA = nil
            }
            Button("取消", role: .cancel) { pendingDeleteIPA = nil }
        } message: {
            if let item = pendingDeleteIPA {
                Text("「\(item.name)」将被永久删除，此操作不可撤销。")
            }
        }
        .alert("两步验证", isPresented: $showTwoFactor) {
            TextField("6 位验证码", text: $twoFactorCode)
                .keyboardType(.numberPad)
            Button("验证") {
                showTwoFactor = false
                let reply = twoFactorReply
                twoFactorReply = nil
                reply?(twoFactorCode)
            }
            Button("取消", role: .cancel) {
                showTwoFactor = false
                let reply = twoFactorReply
                twoFactorReply = nil
                reply?(nil)
            }
        } message: {
            Text("Apple 已向你的受信任设备或短信发送验证码，请输入以完成登录。")
        }
    }

    // MARK: - 下载 IPA

    private func downloadIPA() {
        guard let url = URL(string: ipaLink.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = "链接无效：请输入 http/https 开头的 IPA 直链。"
            return
        }
        errorMessage = nil
        successMessage = nil
        isDownloading = true
        downloadProgress = 0
        Task {
            do {
                let dest = try await download(url: url)
                try FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
                let name = url.lastPathComponent
                let target = customDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: dest, to: target)
                ipaURL = target
                refreshSavedIPAs()
                isDownloading = false
            } catch {
                isDownloading = false
                errorMessage = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    /// 导入的 IPA 复制到 Custom 目录（对齐 SideInstaller 的
    /// IPALibrary.replaceCustomImport），并刷新「已下载的 IPA」列表。
    private func importIPA(from url: URL) {
        do {
            try FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
            let name = url.deletingPathExtension().lastPathComponent + ".ipa"
            let target = customDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            ipaURL = target
            ipaLink = ""
            errorMessage = nil
            successMessage = nil
            refreshSavedIPAs()
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 扫描 Custom 目录里的 IPA（最新在前）。
    private func refreshSavedIPAs() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: customDir.path)) ?? []
        let items = names.compactMap { name -> SavedIPA? in
            guard name.lowercased().hasSuffix(".ipa") else { return nil }
            let url = customDir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return nil }
            return SavedIPA(url: url, name: name, size: size,
                            modified: attrs[.modificationDate] as? Date)
        }
        savedIPAs = items.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    private func deleteSavedIPA(_ item: SavedIPA) {
        try? FileManager.default.removeItem(at: item.url)
        if ipaURL?.path == item.url.path {
            ipaURL = nil
        }
        refreshSavedIPAs()
    }

    private func download(url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        let http = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(http) else {
            throw NSError(domain: "IPAInstall", code: http,
                          userInfo: [NSLocalizedDescriptionKey: "服务器返回 HTTP \(http)"])
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - 自动登录（复用「更多 → 设置」的 Apple ID）

    /// 复用「更多 → 设置」已保存的 Apple ID，**不重复登录/2FA**：
    /// 1) 优先用 dsid + authToken 恢复 isideload 签名会话（免登录免 2FA）；
    /// 2) 恢复失败（token 过期等）才回退用邮箱+密码完整登录（可能弹 2FA）。
    private func autoSignInWithSavedCredentials() {
        guard !service.isSignedIn, !isRunning else { return }
        // warmUp（App 启动后台恢复）正在执行：不重复联网，等它完成——
        // 完成时 @Published isSignedIn 变化会自动刷新页面（v0.2.106 去重）。
        guard !service.isWarmingUp else { return }
        let settings = MemoryLimitSettings.shared
        guard settings.isLoggedIn, !settings.appleID.isEmpty else { return }
        let id = settings.appleID
        let ani = settings.anisetteServer
        isAutoSigningIn = true
        Task {
            do {
                // 路径 1：已有 dsid/authToken → 免 2FA 恢复会话。
                // （预热已失败过则跳过——token 大概率过期，白等一次注定失败的请求）
                // v0.2.112：读 isideload 专用键；`dsid`/`authToken` 属于 Swift 认证
                // 引擎（证书管理/增加内存限制用），两套 Anisette 机器标识不同不能混用。
                if !service.sessionRestoreFailed,
                   let dsid = settings.sideloadDSID, let authToken = settings.sideloadAuthToken,
                   !dsid.isEmpty, !authToken.isEmpty {
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try IPAInstallService.shared.signInWithSession(
                                email: id, dsid: dsid, authToken: authToken, anisetteURL: ani)
                        }.value
                        isAutoSigningIn = false
                        return
                    } catch {
                        // token 失效，回退完整登录。
                    }
                }
                // 路径 2：邮箱+密码完整登录（2FA 走弹窗）。
                let pw = settings.password(forHistory: id) ?? ""
                guard !pw.isEmpty else {
                    isAutoSigningIn = false
                    return
                }
                try await Task.detached(priority: .userInitiated) {
                    try IPAInstallService.shared.signIn(appleID: id, password: pw, anisetteURL: ani)
                }.value
                // 完整登录成功 → 持久化本次拿到的 dsid/authToken，
                // 下次进入（含 App 重启后 warmUp）即可免登录恢复。
                let dsid = service.lastSessionDSID ?? ""
                let authToken = service.lastSessionAuthToken ?? ""
                await MainActor.run {
                    MemoryLimitSettings.shared.saveSessionCredentials(
                        email: id, password: pw, dsid: dsid, authToken: authToken)
                }
            } catch {
                errorMessage = "自动登录失败：\(error.localizedDescription)"
            }
            isAutoSigningIn = false
        }
    }

    // MARK: - 安装流程

    private func startInstall() {
        guard !isRunning, let ipa = ipaURL else { return }
        isRunning = true
        errorMessage = nil
        successMessage = nil
        step = .idle
        installProgress = 0

        let id = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = password
        let anisetteURL = MemoryLimitSettings.shared.anisetteServer

        Task {
            do {
                // 1. 登录（如未登录）
                if !service.isSignedIn {
                    step = .signingIn
                    try await Task.detached(priority: .userInitiated) {
                        try IPAInstallService.shared.signIn(appleID: id, password: pw, anisetteURL: anisetteURL)
                    }.value
                    // 登录成功 → 把邮箱/密码 **以及** 本次登录拿到的 dsid +
                    // xcode.auth token 一起持久化（v0.2.111，isideload fork 暴露）。
                    // 之后 warmUp / 自动登录都能用这两个值免登录免 2FA 恢复。
                    let dsid = service.lastSessionDSID ?? ""
                    let authToken = service.lastSessionAuthToken ?? ""
                    await MainActor.run {
                        MemoryLimitSettings.shared.saveSessionCredentials(
                            email: id, password: pw, dsid: dsid, authToken: authToken)
                    }
                }
                // 2. 签名
                step = .signing
                let signedPath = try await Task.detached(priority: .userInitiated) {
                    try IPAInstallService.shared.signIPA(ipaPath: ipa.path)
                }.value
                // 3. 安装
                step = .installing
                try await Task.detached(priority: .userInitiated) {
                    try IPAInstallService.shared.install(signedAppPath: signedPath) { p in
                        DispatchQueue.main.async {
                            self.installProgress = p
                        }
                    }
                }.value
                step = .done
                successMessage = "「\((signedPath as NSString).lastPathComponent)」已安装到设备。"
            } catch {
                step = .idle
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }
}
