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

    // Apple ID
    @State private var appleID = ""
    @State private var password = ""
    @State private var showPassword = false

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
                ipaURL = url
                ipaLink = ""
                errorMessage = nil
                successMessage = nil
            }
        }
        .onAppear {
            service.twoFactorPrompt = { reply in
                twoFactorCode = ""
                twoFactorReply = reply
                showTwoFactor = true
            }
        }
        .onDisappear {
            service.twoFactorPrompt = nil
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
                ipaURL = dest
                isDownloading = false
            } catch {
                isDownloading = false
                errorMessage = "下载失败：\(error.localizedDescription)"
            }
        }
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
