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

    /// 本机生成 RSA2048 私钥 + CSR；返回 (CSR PEM, 私钥 PEM)。
    /// v0.3.140：私钥不再立即落盘 —— 由 createCertificate 在配对验证通过后统一写入，
    /// 避免提交失败（1100/7460 等）时 keyURL 被新私钥污染（certURL 还是旧证书 → 错位）。
    func generateKeyAndCSR() throws -> (csrPem: String, keyPem: String) {
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
        return (String(cString: csr), String(cString: key))
    }

    /// DER → PEM（证书），64 字符/行标准格式
    static func derToPEM(_ der: Data) -> String {
        let der64 = der.base64EncodedString()
        var pem = "-----BEGIN CERTIFICATE-----\n"
        var idx = der64.startIndex
        while idx < der64.endIndex {
            let end = der64.index(idx, offsetBy: 64, limitedBy: der64.endIndex) ?? der64.endIndex
            pem += der64[idx..<end] + "\n"
            idx = end
        }
        pem += "-----END CERTIFICATE-----\n"
        return pem
    }

    /// 证书 PEM 与私钥 PEM 是否配对（zsign X509_check_private_key）
    static func checkPair(certPem: String, keyPem: String) -> Bool {
        return certPem.withCString { c in
            keyPem.withCString { k in
                zsign_check_pair(c, Int32(strlen(c)), k, Int32(strlen(k))) == 1
            }
        }
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
            // 3) 本机密钥 + CSR（完整 PEM，含头尾——Apple 端点要求原样提交）。
            //    私钥暂存内存，配对验证通过后才落盘（v0.3.140 防错位）。
            let (csrPem, pendingKeyPem) = try generateKeyAndCSR()
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
                    // v0.3.140：候选逐张验证与本机私钥配对 —— Apple 异步签发有延迟，
                    // 历史失败提交的 CSR 可能此刻才被签发，不配对的直接跳过。
                    let candidates = list.filter { !knownSerials.contains($0.serialNumber) && $0.certContent != nil }
                    for cand in candidates {
                        guard let content = cand.certContent else { continue }
                        if Self.checkPair(certPem: Self.derToPEM(content), keyPem: pendingKeyPem) {
                            newCert = cand
                            LoginLogger.shared.log("✓ 新证书已签发且与本地私钥配对（第 \(attempt) 次轮询，serial=\(cand.serialNumber)）")
                            break
                        }
                        LoginLogger.shared.log("⚠ 跳过不配对的新证书 serial=\(cand.serialNumber)（历史提交的延迟签发）")
                    }
                    if newCert != nil { break }
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
            // 6) DER → PEM；同步路径同样验证配对（轮询路径在候选阶段已验证）
            let pem = Self.derToPEM(der)
            if newCert == nil && !Self.checkPair(certPem: pem, keyPem: pendingKeyPem) {
                throw NSError(domain: "DeveloperCert", code: -5,
                              userInfo: [NSLocalizedDescriptionKey: "签发的证书与本机私钥不配对，请重新创建证书"])
            }
            // 7) 配对确认后统一落盘（keyURL 延迟到此刻，杜绝错位状态落盘）
            try pendingKeyPem.write(to: keyURL, atomically: true, encoding: .utf8)
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
    /// 诊断日志（zsign 全部输出 + 分步结果）落盘 dataDir/go_sign_debug.log。
    /// v0.3.152：签名前对比"主程序叶子证书 serial"与"当前证书 serial"——
    /// 150/151 真机实锤主程序用 LC 导入的旧证书（能过校验），新证书签的 dylib 被拒。
    func signDylib(path: String, bundleId: String, debugLog: URL? = nil) -> Bool {
        let team = (try? String(contentsOf: teamURL, encoding: .utf8)) ?? ""
        guard hasCert,
              let certData = try? Data(contentsOf: certURL),
              let keyData = try? Data(contentsOf: keyURL) else {
            LoginLogger.shared.log("❌ signDylib：cert/key 文件读取失败")
            return false
        }
        // v0.3.152 serial 同源诊断：主程序（能过校验的基准）vs 当前签名证书
        let mainSerial = UnsafeMutablePointer<CChar>.allocate(capacity: 96)
        defer { mainSerial.deallocate() }
        let curSerial = UnsafeMutablePointer<CChar>.allocate(capacity: 96)
        defer { curSerial.deallocate() }
        let mainExe = Bundle.main.executablePath ?? ""
        let mainRc = mainExe.withCString { p -> Int32 in
            zsign_file_leaf_serial(p, mainSerial, 96)
        }
        let curRc = certData.withUnsafeBytes { cbuf -> Int32 in
            guard let cp = cbuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -2 }
            return zsign_cert_serial(cp, Int32(certData.count), curSerial, 96)
        }
        if mainRc > 0, curRc > 0 {
            let ms = String(cString: mainSerial)
            let cs = String(cString: curSerial)
            if ms != cs {
                LoginLogger.shared.log("⚠ 证书不同源：主程序 serial=\(ms.suffix(12)) 当前=\(cs.suffix(12))——iOS 27 beta 疑似要求同证书. 请在「证书管理 → 导入 p12」导入主程序同款证书")
            } else {
                LoginLogger.shared.log("✓ 证书同源 serial=\(cs.suffix(12))")
            }
        }
        // v0.3.140 前置配对校验：历史错位（证书对应旧私钥）在此给出明确指引，不让 zsign 模糊失败
        let paired = certData.withUnsafeBytes { cbuf -> Int32 in
            keyData.withUnsafeBytes { kbuf -> Int32 in
                guard let cp = cbuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                      let kp = kbuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
                return zsign_check_pair(cp, Int32(certData.count), kp, Int32(keyData.count))
            }
        }
        if paired != 1 {
            LoginLogger.shared.log("❌ signDylib：证书与私钥不配对（历史创建错位遗留）. 请到「更多 → 证书管理」吊销并重新创建证书")
            return false
        }
        let dbg = debugLog?.path
        let rc = certData.withUnsafeBytes { certBuf -> Int32 in
            keyData.withUnsafeBytes { keyBuf -> Int32 in
                zsign_sign_file_with_cert(path, bundleId,
                                          certBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                                          Int32(certData.count),
                                          keyBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                                          Int32(keyData.count),
                                          nil, 0, dbg, team)
            }
        }
        LoginLogger.shared.log("zsign 真证书签名 rc=\(rc)（0=成功 -1=Init -2=文件/macho -3=Sign）")
        return rc == 0
    }

    /// v0.3.152：导入 p12（同源证书方案）——解析 PKCS12 提取 cert/key PEM，
    /// 配对校验通过后覆盖落盘。用于导入与主程序（LC/SideStore 签发）相同的证书。
    func importP12(data: Data, password: String) -> (ok: Bool, message: String) {
        var certPemOut: UnsafeMutablePointer<CChar>? = nil
        var keyPemOut: UnsafeMutablePointer<CChar>? = nil
        var certLen: Int32 = 0
        var keyLen: Int32 = 0
        let rc = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int32 in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -2 }
            return password.withCString { pwd in
                zsign_p12_extract(base, Int32(data.count), pwd,
                                  &certPemOut, &certLen, &keyPemOut, &keyLen)
            }
        }
        guard rc == 0, let certP = certPemOut, let keyP = keyPemOut else {
            return (false, "p12 解析失败（密码错误或文件损坏）")
        }
        defer {
            free(certP)
            free(keyP)
        }
        let certPem = Data(bytes: certP, count: Int(certLen))
        let keyPem = Data(bytes: keyP, count: Int(keyLen))
        // 配对校验
        let paired = certPem.withUnsafeBytes { cbuf -> Int32 in
            keyPem.withUnsafeBytes { kbuf -> Int32 in
                guard let cp = cbuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                      let kp = kbuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
                return zsign_check_pair(cp, Int32(certPem.count), kp, Int32(keyPem.count))
            }
        }
        guard paired == 1 else {
            return (false, "p12 证书与私钥不配对")
        }
        // serial 记录（与主程序对比的信息源）
        let serialHex = certPem.withUnsafeBytes { cbuf -> String in
            guard let cp = cbuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "?" }
            let out = UnsafeMutablePointer<CChar>.allocate(capacity: 96)
            defer { out.deallocate() }
            let r = zsign_cert_serial(cp, Int32(certPem.count), out, 96)
            return r > 0 ? String(cString: out) : "?"
        }
        do {
            try keyPem.write(to: keyURL, options: .atomic)
            try certPem.write(to: certURL, options: .atomic)
            hasCert = true
            LoginLogger.shared.log("✓ p12 导入成功 serial=\(serialHex.suffix(12))（重启模块后生效）")
            return (true, "导入成功 serial=\(serialHex.suffix(12))（重启模块后生效）")
        } catch {
            return (false, "落盘失败: \(error.localizedDescription)")
        }
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
