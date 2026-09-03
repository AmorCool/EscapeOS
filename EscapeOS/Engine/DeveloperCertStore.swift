//
//  DeveloperCertStore.swift
//  EscapeOS
//
//  v0.3.122：开发证书获取与存储（SideStore/AltSign 同款流程）
//  Apple ID 登录态 → 本机生成 RSA2048 私钥 + CSR（zsign/OpenSSL）→
//  developerservices2 提交 CSR → 存 cert/key PEM → zsign 真证书签名 dylib。
//  真证书签名与 App 同 TeamID → 库验证通过 → dlopen 直接可用。
//

import Foundation

final class DeveloperCertStore: ObservableObject {
    static let shared = DeveloperCertStore()

    /// 证书文件目录：Documents/DeveloperCert/
    private let dir: URL
    private let certURL: URL
    private let keyURL: URL
    private let teamURL: URL

    @Published var hasCert: Bool = false
    @Published var teamId: String?
    @Published var isBusy: Bool = false
    @Published var lastError: String?

    /// 免 JIT 模式（LC 式策略开关）：开启后原生模块用真证书签名加载（不依赖 JIT）。
    @Published var jitFreeMode: Bool {
        didSet { UserDefaults.standard.set(jitFreeMode, forKey: "modules.certSignEnabled") }
    }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("DeveloperCert", isDirectory: true)
        certURL = dir.appendingPathComponent("cert.pem")
        keyURL = dir.appendingPathComponent("key.pem")
        teamURL = dir.appendingPathComponent("teamId.txt")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hasCert = FileManager.default.fileExists(atPath: certURL.path)
                 && FileManager.default.fileExists(atPath: keyURL.path)
        teamId = try? String(contentsOf: teamURL, encoding: .utf8)
        jitFreeMode = UserDefaults.standard.object(forKey: "modules.certSignEnabled") as? Bool ?? true
        autoRevokeEnabled = UserDefaults.standard.object(forKey: "certs.autoRevokeEnabled") as? Bool ?? false
        revokeWhitelist = UserDefaults.standard.string(forKey: "certs.revokeWhitelist") ?? ""
    }

    // MARK: - CSR 生成（zsign/OpenSSL，SideStore CertificatesManager.generateCSR 同款）

    /// 本机生成 RSA2048 私钥 + CSR；私钥落盘，返回 CSR PEM 字符串。
    func generateKeyAndCSR() throws -> String {
        var csrPtr: UnsafeMutablePointer<CChar>?
        var csrLen: Int32 = 0
        var keyPtr: UnsafeMutablePointer<CChar>?
        var keyLen: Int32 = 0
        let rc = zsign_gen_key_csr(&csrPtr, &csrLen, &keyPtr, &keyLen)
        guard rc == 0, let csr = csrPtr, let key = keyPtr else {
            throw NSError(domain: "DeveloperCert", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "CSR/私钥生成失败（rc=\(rc)）"])
        }
        defer {
            free(csrPtr); free(keyPtr)
        }
        let csrPem = String(cString: csr)
        let keyPem = String(cString: key)
        try keyPem.write(to: keyURL, atomically: true, encoding: .utf8)
        return csrPem
    }

    // MARK: - 完整流程：生成 → 提交 Apple → 存储证书

    /// 从存储的登录凭据构造 session（CertificateManager 同款）。
    @MainActor private func makeSession() -> AppleAPISession? {
        let settings = MemoryLimitSettings.shared
        guard let dsid = settings.dsid, let authToken = settings.authToken else { return nil }
        return AppleAPISession(dsid: dsid, authToken: authToken,
                               anisetteData: AnisetteData(
                                   machineID: "", oneTimePassword: "", localUserID: "",
                                   routingInfo: 0, deviceUniqueIdentifier: "", deviceSerialNumber: "",
                                   deviceDescription: "", date: Date(), locale: Locale.current,
                                   timeZone: .current))
    }

    /// 设置页入口：用已登录的 Apple ID 创建开发证书并存储。
    /// （未登录抛错提示先登录；同 Apple ID 新证书 TeamID 相同 → 库验证通过）
    func createCertificateWithStoredAccount() async throws {
        guard let session = await MainActor.run(body: { makeSession() }) else {
            throw NSError(domain: "DeveloperCert", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "请先在上方登录 Apple ID"])
        }
        try await createCertificate(session: session)
    }

    /// 用已登录的 Apple ID 创建开发证书并存储（同 Apple ID 团队 → 库验证通过）。
    /// Apple 现为**异步签发**：submit 只返回受理（certRequest 无证书内容），
    /// 需轮询证书列表等新证书出现后取其 certContent。
    func createCertificate(session: AppleAPISession) async throws {
        guard !isBusy else { return }
        await MainActor.run { isBusy = true; lastError = nil }
        defer { Task { await MainActor.run { self.isBusy = false } } }
        do {
            // 1) 团队解析（免费账号为个人团队；新证书 TeamID 相同 → 库验证通过）
            let teams = try await AppleDeveloperAPI.fetchTeams(session: session)
            guard let team = teams.first else {
                throw NSError(domain: "DeveloperCert", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "账号下没有开发者团队"])
            }
            // 2) 提交前记录已有序列号（用于识别新证书）
            let before = try await AppleDeveloperAPI.fetchCertificates(team: team, session: session)
            let knownSerials = Set(before.map { $0.serialNumber })
            // 3) 本机密钥 + CSR（完整 PEM，含头尾——Apple 端点要求原样提交）
            let csrPem = try generateKeyAndCSR()
            // 4) 提交 Apple（异步受理：响应只含 certRequest 元数据，无证书内容）。
            //    7460（证书数上限，免费账号常见）→ SideStore 同款：吊销全部旧证书后重试一次。
            //    （被吊销的旧证书所属工具下次使用时会自动重建自己的证书，属正常行为）
            let machineName = (UIDevice.current.name)
            var certDER: Data
            do {
                certDER = try await AppleDeveloperAPI.submitSigningCertificate(
                    team: team, csrPEM: csrPem, machineName: machineName, session: session)
            } catch let err as AppleAPIError {
                if case .customError(let code, _) = err, code == 7460 {
                    // v0.3.131：走统一撤销接口（受「自动撤销证书」开关与白名单管控）
                    let (revoked, blocked) = await revokeAllForModuleLoading(
                        team: team, session: session)
                    guard !blocked, revoked > 0 else {
                        throw AppleAPIError.customError(
                            code: 7460,
                            message: "开发证书数量已达上限（7460）。未设置自动撤销证书，请手动撤销（更多 → 证书管理）")
                    }
                    certDER = try await AppleDeveloperAPI.submitSigningCertificate(
                        team: team, csrPEM: csrPem, machineName: machineName, session: session)
                } else {
                    throw err
                }
            }
            // 5) 同步拿到内容则直接用；异步受理（空内容）则轮询证书列表（最多 30 秒）
            var newCert: DeveloperCertificate?
            if !certDER.isEmpty {
                LoginLogger.shared.log("✓ 提交响应即含证书内容（同步签发）")
            } else {
                for attempt in 1...10 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let list = try await AppleDeveloperAPI.fetchCertificates(team: team, session: session)
                    newCert = list.first { !knownSerials.contains($0.serialNumber) && $0.certContent != nil }
                    if let c = newCert {
                        LoginLogger.shared.log("✓ 新证书已签发（第 \(attempt) 次轮询，serial=\(c.serialNumber)）")
                        break
                    }
                }
            }
            let der: Data
            if let c = newCert, let content = c.certContent {
                der = content
            } else if !certDER.isEmpty {
                der = certDER
            } else {
                throw NSError(domain: "DeveloperCert", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "证书签发处理超时（30 秒），请稍后在「证书管理」查看并重试"])
            }
            // 6) DER → PEM 存储
            let der64 = der.base64EncodedString()
            var pem = "-----BEGIN CERTIFICATE-----\n"
            var idx = der64.startIndex
            while idx < der64.endIndex {
                let end = der64.index(idx, offsetBy: 64, limitedBy: der64.endIndex) ?? der64.endIndex
                pem += der64[idx..<end] + "\n"
                idx = end
            }
            pem += "-----END CERTIFICATE-----\n"
            try pem.write(to: certURL, atomically: true, encoding: .utf8)
            try team.identifier.write(to: teamURL, atomically: true, encoding: .utf8)
            await MainActor.run {
                hasCert = true
                teamId = team.identifier
            }
        } catch {
            let msg = (error as NSError).localizedDescription
            await MainActor.run { lastError = msg }
            throw error
        }
    }

    // MARK: - 真证书签名

    /// 对 dylib 就地做真证书签名。返回 true = 签名成功。
    func signDylib(path: String, bundleId: String) -> Bool {
        guard hasCert,
              let certData = try? Data(contentsOf: certURL),
              let keyData = try? Data(contentsOf: keyURL) else { return false }
        let rc = certData.withUnsafeBytes { certBuf -> Int32 in
            keyData.withUnsafeBytes { keyBuf -> Int32 in
                zsign_sign_file_with_cert(path, bundleId,
                                          certBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                                          Int32(certData.count),
                                          keyBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                                          Int32(keyData.count),
                                          nil, 0)
            }
        }
        return rc == 0
    }

    /// 统一撤销接口：自动撤销开关（默认关——防止误吊销 SideStore 在用证书）
    @Published var autoRevokeEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRevokeEnabled, forKey: "certs.autoRevokeEnabled") }
    }
    /// 白名单（仅支持一个）：证书名包含该字符串则不吊销（如 "SideStore"）
    @Published var revokeWhitelist: String {
        didSet { UserDefaults.standard.set(revokeWhitelist, forKey: "certs.revokeWhitelist") }
    }

    /// 统一撤销调用点：吊销团队下全部开发证书（白名单与 SideStore/AltStore 标识放行）。
    /// 返回 (吊销数, 是否被开关拦下)。未开自动撤销 → 输出日志并拦下（调用方自行提示）。
    @discardableResult
    func revokeAllForModuleLoading(team: DeveloperTeam,
                                   session: AppleAPISession) async -> (revoked: Int, blocked: Bool) {
        guard autoRevokeEnabled else {
            LoginLogger.shared.log("⚠ 未设置自动撤销证书，请手动撤销（更多 → 证书管理）")
            return (0, true)
        }
        let whitelist = revokeWhitelist.trimmingCharacters(in: .whitespaces)
        do {
            let certs = try await AppleDeveloperAPI.fetchCertificates(team: team, session: session)
            var revoked = 0
            for cert in certs {
                let name = cert.name
                let lowered = name.lowercased()
                if !whitelist.isEmpty, name.contains(whitelist) {
                    LoginLogger.shared.log("⏭ 白名单放行：\(name)")
                    continue
                }
                if lowered.contains("sidestore") || lowered.contains("altstore") {
                    LoginLogger.shared.log("⏭ SideStore/AltStore 标识放行：\(name)")
                    continue
                }
                do {
                    try await AppleDeveloperAPI.revokeCertificate(
                        team: team, serialNumber: cert.serialNumber, session: session)
                    LoginLogger.shared.log("✓ 已吊销旧证书：\(name)（serial=\(cert.serialNumber)）")
                    revoked += 1
                } catch {
                    LoginLogger.shared.log("❌ 吊销失败：\(name)——\((error as NSError).localizedDescription)")
                }
            }
            LoginLogger.shared.log("✓ 统一撤销完成：吊销 \(revoked)/\(certs.count) 张（白名单与 SideStore/AltStore 放行不计）")
            return (revoked, false)
        } catch {
            LoginLogger.shared.log("❌ 统一撤销失败（获取证书列表）：\((error as NSError).localizedDescription)")
            return (0, false)
        }
    }

    /// 删除证书（吊销由 CertificateManager 负责；此处仅清本地）。
    func removeLocal() {
        try? FileManager.default.removeItem(at: certURL)
        try? FileManager.default.removeItem(at: keyURL)
        try? FileManager.default.removeItem(at: teamURL)
        hasCert = false
        teamId = nil
    }
}
