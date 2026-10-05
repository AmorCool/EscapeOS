import Foundation
import CryptoKit

// 共享转换 · 目标设备「修补」服务
//
// 职责：把用户自己传到本机的共享 IPA 修补成「本机能装的包」并安装。
//   · 加密包（cryptid=1）：取包内既有 sinf → 全铺到全部 SC_Info/*.sinf → 不重签 → 安装 → 启动自检。
//   · 明文包（cryptid=0）：跳过 sinf，但**同样**走「安装前确认 + 实装实跑自检」后安装
//     （现状：设备内无整包 zsign，重签分支落不实）。
//
// 事实依据（详见 `P0_工作产物标准区/EscapeSpace-共享转换/repair/报告-目标设备修补流程.md`）：
//   · sinf 与「请求 udid / 设备硬件」无关（绑服务端账号 + 内容密钥）⇒ 不重取，直接用包内那份。
//   · 同一 IPA 内所有 sinf 逐字节相同 ⇒ 「一份 sinf 铺满全部路径」在语义上完备。
//   · 【顺序铁律】重签包把 SC_Info 封进了 `_CodeSignature/CodeResources` 的 files ⇒
//     任何「换 sinf + 重签」的组合都必须 **先换 sinf、后签名**，否则签名失效。
//     本线加密包不重签（保留 Apple 原始签名，走 installd 的 Customer / ApplicationSINF 通道），
//     所以当前不触发；但注入必须排在签名之前（若将来引入整包重签）。
//
// 依赖（均已存在，直接复用）：IPAPackageInspector / PackageSINFWriter /
//   AppStoreInstallService / IPADownloadLibrary / HostCapabilityService / JITEnableService。

// MARK: - 输入 / 输出模型

/// 修补请求。落盘后的 IPA 路径 + 发送端 / 导入侧 manifest 里的关键字段。
struct RepairRequest {
    /// `Documents/Imports/<name>.ipa`（导入路径落盘处）
    let ipaPath: String
    let manifest: RepairManifest
    /// 安装完成后是否做「实装实跑」自检（默认 true）
    let runLaunchCheck: Bool

    init(ipaPath: String, manifest: RepairManifest, runLaunchCheck: Bool = true) {
        self.ipaPath = ipaPath
        self.manifest = manifest
        self.runLaunchCheck = runLaunchCheck
    }
}

/// 修补流程用得到的 manifest 子集（完整 manifest 由传输 / 导入层定义）。
/// `Codable`：导入层把它嵌进 `ImportRecord` 落 `imports.json`。
struct RepairManifest: Codable {
    var bundleId: String?
    /// App Store trackId（用于 `song` 校验）；缺失时兜底读包内 `iTunesMetadata.itemId`
    var storeItemId: String?
    /// "encryptedIPA" | "decryptedIPA"
    var payloadKind: String
    var payloadSha256: String?
    /// 发送端当初的源（**仅作台账 / 排障**，修补流程不据此重取 sinf）
    var sourceHint: String?

    init(bundleId: String? = nil,
         storeItemId: String? = nil,
         payloadKind: String,
         payloadSha256: String? = nil,
         sourceHint: String? = nil) {
        self.bundleId = bundleId
        self.storeItemId = storeItemId
        self.payloadKind = payloadKind
        self.payloadSha256 = payloadSha256
        self.sourceHint = sourceHint
    }
}

/// 成功时：包内那份 sinf 的元信息 + 实际写入的全部路径。
struct SinfInfo {
    let length: Int
    let format: String           // "sinf-TLV" / "superblob" / "unknown"
    let song: UInt32?            // = trackId 低 32 位
    let accountName: String?     // schi.name（展示时脱敏）
    let sha256: String
    let writtenPaths: [String]   // 实际写入包内的全部 SC_Info 路径（含 framework / appex）
}

/// 修补结果（对应报告 Q4.3）。
struct RepairResult {
    enum Stage: String {
        case verifyPackage   // (1)(2) 落盘确认 + sha256
        case inspectPackage  // (3) 结构 / cryptid
        case checkSinf       // (4) 包内 sinf 体检
        case gatherSinf      // (5) 取定「要铺的那份 sinf」= 包内既有（不重取）
        case validateSinf    // (6) 自检（防垃圾件）
        case injectSinf      // (7) 全铺到全部 SC_Info 路径
        case resign          // (8) 明文包重签（先换 sinf 后签名）
        case install         // (9) 安装
        case ledger          // (10) 台账
        case launchCheck     // (11) 实装实跑启动自检
    }
    enum Status: String { case ok, failed, skipped, needsUserChoice }

    let status: Status
    /// 成功 = 最后完成的 stage；失败 = 卡在哪个 stage
    let stage: Stage
    /// 机器可读原因码（E1…E10）
    let code: String?
    /// 一句人话
    let message: String
    /// 一句「你可以怎么办」
    let suggestion: String
    /// 各步骤原始细节（日志 / 字节数 / 错误原文），供「详情」折叠区展示
    let details: [String]
    let sinf: SinfInfo?
    let repairedIPAPath: String?

    static func failure(_ stage: Stage, code: String, message: String,
                        suggestion: String, details: [String] = []) -> RepairResult {
        RepairResult(status: .failed, stage: stage, code: code, message: message,
                     suggestion: suggestion, details: details, sinf: nil, repairedIPAPath: nil)
    }
}

// MARK: - 修补服务

/// 目标设备上的「修补」服务。**无状态门面**，可直接 `static` 调用。
enum RepairService {

    /// 把共享来的 IPA 修补成「本机能装的包」。
    ///
    /// 全程不吞异常、不静默：每一步都写 `LoginLogger`（category: `.appStore`）并回报 `RepairResult`。
    ///
    /// - Parameter confirmInstall: 「安装前确认」钩子（三步确认的第三步）。
    ///   在**注入 sinf 之后、调用 installd 之前** `await`；返回 `false` 表示用户取消安装，
    ///   此时函数返回 `.skipped`（包已被注入，但**不安装**）。为 `nil` 时不做安装前确认。
    static func repair(_ req: RepairRequest,
                       progress: (@Sendable (Double, String) -> Void)? = nil,
                       onLog: (@Sendable (String) -> Void)? = nil,
                       confirmInstall: (@MainActor () async -> Bool)? = nil) async -> RepairResult {

        var log: [String] = []
        func note(_ s: String) {
            log.append(s)
            onLog?(s)
            LoginLogger.shared.log("[共享修补] \(s)", category: .appStore)
        }

        // ── (1) 落盘确认 ─────────────────────────────────────────────
        guard FileManager.default.fileExists(atPath: req.ipaPath) else {
            return .failure(.verifyPackage, code: "E1",
                message: "没找到刚收到的安装包.",
                suggestion: "回到上一步重新接收一次；若已删除，请对方重新分享.",
                details: log)
        }

        // ── (2) 完整性校验（sha256）──────────────────────────────────
        if let expect = req.manifest.payloadSha256, !expect.isEmpty {
            guard let actual = sha256Hex(ofFileAt: req.ipaPath) else {
                return .failure(.verifyPackage, code: "E2",
                    message: "安装包读取失败.",
                    suggestion: "删掉这个包，让发送方重新传一次.", details: log)
            }
            guard actual.caseInsensitiveCompare(expect) == .orderedSame else {
                return .failure(.verifyPackage, code: "E2",
                    message: "安装包不完整（传输中损坏）.",
                    suggestion: "删掉这个包，让发送方重新传一次（建议同一 Wi-Fi 下重传）.",
                    details: log + ["sha256 期望 \(expect.prefix(16))… 实际 \(actual.prefix(16))…"])
            }
            note("sha256 校验通过")
        } else {
            note("manifest 未给 sha256，跳过完整性校验")
        }

        // ── (3) 结构 + 加密判定 ──────────────────────────────────────
        guard let ins = IPAPackageInspector.inspect(ipaPath: req.ipaPath) else {
            return .failure(.inspectPackage, code: "E3",
                message: "这个文件不是可安装的 IPA（缺 Payload/Info.plist）.",
                suggestion: "确认对方分享的是 .ipa 而不是别的文件.", details: log)
        }
        note("包信息：\(ins.bundleIdentifier ?? "-") \(ins.bundleVersion ?? "-") · \(ins.summary)")

        // （可选增强）HostCapabilityService.pkg.stat 的 zip 结构体检。
        //   App 内可直调（HostCapabilityService.call 是普通 Swift 方法）；但：
        //     ① 会写 caplog（排障信号）；② 解析失败 / 不可用 ⇒ 必须降级，不阻断主流程。
        if let stat = hostPkgStat(path: req.ipaPath) {
            let testzipOk = stat["testzipOk"] as? Bool ?? false
            let orphan = stat["orphanLocalCount"] as? Int ?? 0
            if !testzipOk || orphan > 0 {
                note("pkg.stat 结构体检异常：testzipOk=\(testzipOk) orphanLocalCount=\(orphan)（降级：不阻断，继续）")
            } else {
                note("pkg.stat 结构体检通过（testzipOk=true, orphanLocalCount=0）")
            }
        } else {
            note("pkg.stat 不可用，跳过结构体检（降级：仅用 IPAPackageInspector）")
        }

        // ── (3A) 明文包分支 ─────────────────────────────────────────
        if ins.isEncrypted == false {
            note("明文包（cryptid=0），不需要 sinf")
            return await installPlainPackage(req, ins: ins, log: log, note: note,
                                             progress: progress, confirmInstall: confirmInstall)
        }

        // ── (4) 包内 sinf 体检 ───────────────────────────────────────
        guard let rawSinf = IPAPackageInspector.extractSINF(ipaPath: req.ipaPath) else {
            // 包内完全没有 sinf ⇒ 无源可补（本机不能凭空签发）→ E4
            return .failure(.checkSinf, code: "E4",
                message: "这个安装包里没有解密授权（sinf），本机无法补齐.",
                suggestion: "请对方分享原始加密包（而不是已重签 / 已处理的包）；或改用「同 Apple ID 正规重下」.",
                details: log)
        }
        note("包内已有 sinf（\(rawSinf.count) 字节）—— 按本线，直接用它（sinf 与设备无关）")

        // ── (5) 取定「要铺的那份 sinf」= 包内既有（不重取）───────────
        let sinfData = rawSinf

        // ── (6) sinf 自检（写入前，防垃圾件）─────────────────────────
        guard PackageSINFWriter.isStructurallyValidSinf(sinfData) else {
            return .failure(.validateSinf, code: "E5",
                message: "包里的解密授权格式不合法，已拒绝写入（宁可装不上也不写坏包）.",
                suggestion: "让对方重新分享一次原始包；持续失败请反馈日志.", details: log)
        }
        let parsed = parseSinf(sinfData)
        if let expectedSong = trackIdLow32(req: req, ins: ins),
           let got = parsed.song, got != expectedSong {
            return .failure(.validateSinf, code: "E5b",
                message: "包里的解密授权不属于这个应用（商品号对不上）.",
                suggestion: "让对方确认分享的是正确的 App；持续失败请反馈.",
                details: log + ["期望 song=\(expectedSong) 实际=\(got)"])
        }
        note("sinf 自检通过：\(sinfData.count) 字节 · \(parsed.format)"
             + (parsed.song.map { " · song=\($0)" } ?? ""))

        // ── (7) 全铺 sinf（全部 SC_Info 路径）────────────────────────
        // 复用 PackageSINFWriter.injectAllPaths（一次整包重写批量替换 + 写后逐条复读）。
        let written: [String]
        do {
            written = try PackageSINFWriter.injectAllPaths(sinf: sinfData, ipaPath: req.ipaPath)
        } catch {
            return .failure(.injectSinf, code: "E6",
                message: "把解密授权写进安装包时失败.",
                suggestion: "确认存储空间充足后重试；持续失败请反馈.",
                details: log + ["\(error)"])
        }
        note("已写入 \(written.count) 条 sinf 路径：\(written.joined(separator: ", "))")

        // ── (8) 加密包：不重签（保留 Apple 原始签名，走 Customer 通道）──
        // 依据：installWithSINF 用 PackageType=Customer + ApplicationSINF，不校验 _CodeSignature。
        // 顺序铁律（若将来引入整包重签）：先换 sinf、后签名 —— 见文件头注释。

        // ── (9) 安装（三步确认的第三步：安装前确认）────────────────────
        if let confirmInstall, !(await confirmInstall()) {
            note("用户在安装前取消")
            return RepairResult(status: .skipped, stage: .install, code: nil,
                message: "已取消安装（安装包已修补，可稍后重试）.",
                suggestion: "如需继续，请重新点一次安装.",
                details: log, sinf: nil, repairedIPAPath: req.ipaPath)
        }
        do {
            try await AppStoreInstallService.installLocalIPA(
                req.ipaPath,
                progress: { p in progress?(p, "安装中") },
                onLog: { note($0) })
        } catch {
            let msg = error.localizedDescription
            let isAccount = msg.localizedCaseInsensitiveContains("sinf")
                || msg.localizedCaseInsensitiveContains("SINF")
            let code = isAccount ? "E8b" : "E8"
            return .failure(.install, code: code,
                message: isAccount
                    ? "此安装包属于另一个 Apple ID，本机无法安装运行."
                    : "安装被系统拒绝.",
                suggestion: isAccount
                    ? "在本机登录与发送方相同的 Apple ID 后重试；或改用「同 Apple ID 正规重下」."
                    : "重试；若持续失败请反馈日志.",
                details: log + [msg])
        }
        note("安装完成")

        // ── (10) 台账（「重装不用重下」）─────────────────────────────
        IPADownloadLibrary.shared.record(
            fileURL: URL(fileURLWithPath: req.ipaPath),
            displayName: ins.displayName, bundleId: ins.bundleIdentifier,
            version: ins.bundleVersion, iconURL: nil,
            source: "共享", sourceURL: nil,
            storeItemId: req.manifest.storeItemId,
            sinfBase64: sinfData.base64EncodedString())
        note("已记台账（source=共享，含包内那份 sinf）")

        // ── (11) 实装实跑、逐层定位阻断 ─────────────────────────────
        // 安装返回成功 ≠ 能跑（形态 B：装得上、启动崩）。
        var launchStage: RepairResult.Stage = .ledger
        var launchCode: String? = nil
        var launchMsg = "修补并安装完成."
        var launchSuggest = "若首次启动异常退出，说明包内授权不属于本机登录的 Apple ID，请反馈日志."
        if req.runLaunchCheck {
            switch await LaunchProbe.probe(bundleId: ins.bundleIdentifier,
                                           executable: ins.executable,
                                           note: note) {
            case .alive:
                launchStage = .launchCheck
                launchMsg = "修补、安装、启动自检均通过."
                launchSuggest = "如使用中仍有异常，请反馈日志."
            case .neverAppeared:
                launchStage = .launchCheck; launchCode = "E10"
                launchMsg = "安装完成，但应用启动后没能运行起来."
                launchSuggest = "请手动点一次图标看看；若仍打不开，请把包退回并用你自己的 Apple ID 正规下载."
            case .crashed:
                launchStage = .launchCheck; launchCode = "E9"
                launchMsg = "装上了，但一启动就退出（包内授权不属于本机登录的 Apple ID）."
                launchSuggest = "这是别人的授权装到你设备上的典型表现，本功能无法修复；请用你自己的 Apple ID 正规下载."
            case .unavailable:
                launchStage = .launchCheck
                note("proc.list / 拉起应用不可用，跳过实装实跑自检（降级：仅安装成功）")
            }
        }

        return RepairResult(
            status: .ok, stage: launchStage, code: launchCode,
            message: launchMsg, suggestion: launchSuggest,
            details: log,
            sinf: SinfInfo(length: sinfData.count, format: parsed.format,
                           song: parsed.song, accountName: parsed.name,
                           sha256: sha256Hex(of: sinfData), writtenPaths: written),
            repairedIPAPath: req.ipaPath)
    }

    // MARK: 明文包分支

    /// cryptid=0：跳过 sinf，直接安装。
    /// ⚠️ 现状：设备内没有「整包 zsign」（`ZSign/zsign.mm` 只逐 Mach-O ad-hoc，不产
    /// `_CodeSignature/CodeResources`）⇒ 需要重签的明文包这条分支**当前落不实**。
    /// 顺序铁律（若未来落地）：先换 sinf、后签名。
    ///
    /// **三步确认的第三步同样适用**：安装前 `await confirmInstall`，取消 → `.skipped`、不安装；
    /// 安装后与加密包分支一致地做「实装实跑」自检（`runLaunchCheck`）。
    private static func installPlainPackage(_ req: RepairRequest,
                                            ins: IPAPackageInspector.Inspection,
                                            log: [String],
                                            note: @escaping (String) -> Void,
                                            progress: (@Sendable (Double, String) -> Void)?,
                                            confirmInstall: (@MainActor () async -> Bool)?) async -> RepairResult {
        // 安装前确认（与加密包分支一致）：用户取消 → 不安装，返回 .skipped。
        if let confirmInstall, !(await confirmInstall()) {
            note("用户在安装前取消")
            return RepairResult(status: .skipped, stage: .install, code: nil,
                message: "已取消安装（明文包无需修补，可稍后重试）.",
                suggestion: "如需继续，请重新点一次安装.",
                details: log, sinf: nil, repairedIPAPath: req.ipaPath)
        }
        do {
            try await AppStoreInstallService.installLocalIPA(
                req.ipaPath,
                progress: { p in progress?(p, "安装中") },
                onLog: { note($0) })
        } catch {
            return .failure(.install, code: "E8",
                message: "安装被系统拒绝.",
                suggestion: "重试；若持续失败请反馈日志.",
                details: log + [error.localizedDescription])
        }
        IPADownloadLibrary.shared.record(
            fileURL: URL(fileURLWithPath: req.ipaPath),
            displayName: ins.displayName, bundleId: ins.bundleIdentifier,
            version: ins.bundleVersion, iconURL: nil,
            source: "共享", storeItemId: req.manifest.storeItemId, sinfBase64: nil)
        note("已记台账（source=共享）")

        // 实装实跑自检（与加密包分支一致）：安装返回成功 ≠ 能跑。
        var launchStage: RepairResult.Stage = .ledger
        var launchCode: String? = nil
        var launchMsg = "安装完成（明文包，无需修补）."
        var launchSuggest = "如使用中仍有异常，请反馈日志."
        if req.runLaunchCheck {
            switch await LaunchProbe.probe(bundleId: ins.bundleIdentifier,
                                           executable: ins.executable,
                                           note: note) {
            case .alive:
                launchStage = .launchCheck
                launchMsg = "安装、启动自检均通过（明文包，无需修补）."
                launchSuggest = "如使用中仍有异常，请反馈日志."
            case .neverAppeared:
                launchStage = .launchCheck; launchCode = "E10"
                launchMsg = "安装完成，但应用启动后没能运行起来."
                launchSuggest = "请手动点一次图标看看；若仍打不开，请把包退回并重新获取."
            case .crashed:
                launchStage = .launchCheck; launchCode = "E9"
                launchMsg = "装上了，但一启动就退出."
                launchSuggest = "请用你自己的 Apple ID 正规下载；若持续失败请反馈日志."
            case .unavailable:
                launchStage = .launchCheck
                note("proc.list / 拉起应用不可用，跳过实装实跑自检（降级：仅安装成功）")
            }
        }

        return RepairResult(status: .ok, stage: launchStage, code: launchCode,
            message: launchMsg, suggestion: launchSuggest,
            details: log, sinf: nil, repairedIPAPath: req.ipaPath)
    }

    // MARK: 小工具

    /// trackId 低 32 位（用于 `song` 校验）；manifest 没有就兜底读包内 `iTunesMetadata.itemId`。
    private static func trackIdLow32(req: RepairRequest,
                                     ins: IPAPackageInspector.Inspection) -> UInt32? {
        var id = req.manifest.storeItemId
        if (id ?? "").isEmpty,
           let meta = IPAPackageInspector.extractiTunesMetadata(ipaPath: req.ipaPath),
           let plist = try? PropertyListSerialization.propertyList(from: meta, options: [], format: nil),
           let dict = plist as? [String: Any] {
            id = (dict["itemId"] as? NSNumber)?.stringValue ?? (dict["itemId"] as? String)
        }
        guard let s = id, let v = UInt64(s) else { return nil }
        return UInt32(truncatingIfNeeded: v)
    }

    /// 直调 `pkg.stat`（JSON 字符串入参），拿 `zip.testzipOk` / `orphanLocalCount`。
    /// 不可用（未实现 / 门禁拒绝 / 解析失败）→ nil，调用方降级。
    private static func hostPkgStat(path: String) -> [String: Any]? {
        let args = "{\"path\":\(jsonString(path))}"
        let (rc, json) = HostCapabilityService.call(capability: "pkg.stat", jsonArgs: args)
        guard rc == 0,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zip = obj["zip"] as? [String: Any] else { return nil }
        return zip
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data()
        // 去掉首尾的 [ ]
        var t = String(data: data, encoding: .utf8) ?? "\"\""
        if t.hasPrefix("["), t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
        return t
    }

    // MARK: sha256

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 流式 sha256（不整包读进内存）。
    ///
    /// **读取错误必须中止，绝不返回部分哈希**：`read(upToCount:)` 的 `nil` 既可能是 EOF，
    /// 也可能来自错误；旧实现用 `try?` 把两者压成同一个 `nil`，中途读错会返回**已读部分的
    /// 哈希**并当作成功——这正是本项目反复踩过的「静默错误答案」。
    /// 现在只有 `nil` / 空块才算 EOF；任一 `throw` 都返回 `nil`，由调用方按「读取失败」处理。
    static func sha256Hex(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        return sha256Hex(readingChunks: { try fh.read(upToCount: 1 << 20) })
    }

    /// 流式 sha256 的核心（独立可测）：`read` 依次返回下一块，`nil` 或空块表示 EOF。
    /// 任一 `read` 抛错 → 整体返回 `nil`（**不产出任何哈希**）。
    static func sha256Hex(readingChunks read: () throws -> Data?) -> String? {
        var hasher = SHA256()
        do {
            while true {
                guard let chunk = try read(), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
        } catch {
            LoginLogger.shared.log("[共享] 读取失败，已中止 sha256（不返回部分哈希）：\(error)",
                                   category: .appStore)
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 实装实跑探测

/// 安装后「进程能否起、能否活」的探测。
/// 复用 `JITEnableService.launchApp(bundleID:)` 拉起应用，再用 `HostCapabilityService.proc.list`
/// 采样 0 / 1 / 3 / 5 秒，看目标进程是否出现并存活。
enum LaunchProbe {
    enum Outcome { case alive, crashed, neverAppeared, unavailable }

    static func probe(bundleId: String?, executable: String?,
                      note: (String) -> Void) async -> Outcome {
        guard let bundleId, !bundleId.isEmpty else { return .unavailable }

        // 1) 拉起应用（普通启动）
        do {
            try JITEnableService.shared.launchApp(bundleID: bundleId)
        } catch {
            note("拉起应用失败：\(error.localizedDescription)")
            return .unavailable
        }

        let needle = (executable?.isEmpty == false ? executable! : bundleId)
        // 2) 采样：0 / 1 / 3 / 5 秒
        var everSeen = processExists(needle)
        if !everSeen {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            everSeen = processExists(needle)
        }
        if !everSeen {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            everSeen = processExists(needle)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let stillAlive = processExists(needle)

        if everSeen && stillAlive { return .alive }
        if everSeen && !stillAlive { return .crashed }
        return .neverAppeared
    }

    /// 目标进程是否在 `proc.list` 里（按可执行名 / bundleId 匹配 name 或 path）。
    private static func processExists(_ needle: String) -> Bool {
        let (rc, json) = HostCapabilityService.call(capability: "proc.list", jsonArgs: "{}")
        guard rc == 0,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let procs = obj["processes"] as? [[String: Any]] else { return false }
        return procs.contains { p in
            let name = (p["name"] as? String) ?? ""
            let path = (p["path"] as? String) ?? ""
            return name == needle || name.contains(needle) || path.contains(needle)
        }
    }
}

// MARK: - sinf 解析（取 schi.name / righ.song）

/// 极简解析：只取修补流程用到的两个字段。
/// 完整块解析规范见 `P3_爱思助手_NB逆向工作区/_work_sinf_spec/sinf-格式规范.md`。
struct ParsedSinf {
    let format: String      // "sinf-TLV" / "superblob" / "unknown"
    let name: String?       // schi.name（取包账号名）
    let song: UInt32?       // righ.song（= trackId 低 32 位）
}

/// TLV 容器：`{4B 大端总长}"sinf"{块序列}`，块 = `{4B 大端块长}{4B tag}{body}`（块长含 8B 头）。
/// 顶层块固定 4 个：`frma → schm → schi → sign`。
/// `schi` 的 body 是**裸子块序列**（无自己的长度头）；`name`（账号名）与 `righ`（权限项）
/// **都在 `schi` 内部**（不是顶层块）—— `righ` 的 body 是定长 8 字节 `{4B tag}{4B 大端值}` 键值对。
/// 前 4 字节是**长度**不是固定魔数（1056 字节的合法件头是 `00 00 04 20 "sinf"`）。
func parseSinf(_ d: Data) -> ParsedSinf {
    let b = [UInt8](d)
    guard b.count >= 8 else { return ParsedSinf(format: "unknown", name: nil, song: nil) }

    guard Array(b[4..<8]) == Array("sinf".utf8) else {
        let magic = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        return ParsedSinf(format: magic == 0xFADE0CC0 ? "superblob" : "unknown", name: nil, song: nil)
    }

    var name: String?
    var song: UInt32?
    var off = 8
    while off + 8 <= b.count {
        let blockLen = Int(sinfBE32(b, off))
        let tag = String(bytes: b[(off + 4)..<(off + 8)], encoding: .ascii) ?? ""
        guard blockLen >= 8, off + blockLen <= b.count else { break }
        if tag == "schi" {
            let parsed = sinfParseSchi(b, off + 8, off + blockLen)
            name = parsed.name
            song = parsed.song
        }
        off += blockLen
    }
    return ParsedSinf(format: "sinf-TLV", name: name, song: song)
}

private func sinfBE32(_ b: [UInt8], _ o: Int) -> UInt32 {
    guard o + 4 <= b.count else { return 0 }
    return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
}

/// 遍历 `schi` 的裸子块序列，取 `name`（256B 定长、UTF-8、NUL 补齐）与 `righ`（→ `song`）。
private func sinfParseSchi(_ b: [UInt8], _ start: Int, _ end: Int) -> (name: String?, song: UInt32?) {
    var name: String?
    var song: UInt32?
    var off = start
    while off + 8 <= end {
        let len = Int(sinfBE32(b, off))
        let tag = String(bytes: b[(off + 4)..<(off + 8)], encoding: .ascii) ?? ""
        guard len >= 8, off + len <= end else { break }
        if tag == "name" {
            let body = b[(off + 8)..<(off + len)]
            name = String(bytes: body.prefix { $0 != 0 }, encoding: .utf8)
        } else if tag == "righ" {
            song = sinfParseRighSong(b, off + 8, off + len)
        }
        off += len
    }
    return (name, song)
}

/// `righ` body = 定长 8B `{4B tag}{4B 大端值}` 键值对；取 `song`。
private func sinfParseRighSong(_ b: [UInt8], _ start: Int, _ end: Int) -> UInt32? {
    var off = start
    while off + 8 <= end {
        let tag = String(bytes: b[off..<(off + 4)], encoding: .ascii) ?? ""
        if tag == "song" { return sinfBE32(b, off + 4) }
        off += 8
    }
    return nil
}
