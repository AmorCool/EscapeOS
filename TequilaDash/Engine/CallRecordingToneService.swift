import Foundation

// MARK: - 禁用通话录音提示音（移植 AirBeep）
//
// ## 原理（来自 AirBeep / 原名 Placard，仓库 `LinkPass888/AirBeep`）
// 通话录音开始 / 结束时会播放一段**披露提示音**（disclosure tone），文件落在
// `/var/mobile/Library/CallServices/Greetings/default/`：
//   · 开始：`StartDisclosureWithTone.m4a`
//   · 结束：`StopDisclosure.caf`
// AirBeep 的做法：把这两个文件**替换成等长静音**（时长、容器、采样率一致，只是内容全零）。
// 系统照常播放「一个文件」，只是听不到提示音；**录音本身不受影响**。
//
// ## 本仓怎么落地
// 替换写入经 `AirLiftService` —— 真 airlift：**配对文件 + LocalDevVPN 隧道**在设备上
// 直接驱动 AirTraffic（Rust `libairlift_ffi.a`，见 `Engine/Airlift/`），
// **不再**经 `SandboxEscape` / bad_query。静音素材改用 AirBeep 的**等长静音文件**
// （`Resources/SilentTones/`，与原始提示音同容器同时长），不再用 AVFoundation 现生成。
// 原始提示音在首次禁用时**备份到 App 自己的 Documents**，可一键恢复。
//
// ## 诚实边界
// · **本机（Windows）无法编译 / 实机验证**，格式与时长按 AirBeep 钉死的素材为准，实机行为待真机复测。
// · 状态判据用持久化标记（`UserDefaults`）而非文件内容比对 —— 因为 PCM 静音与原音
//   **长度相同、字节数也相同**，按大小无法区分；故如实说明「状态以本 App 的标记为准」。
// · 写入需**导入配对文件 + LocalDevVPN 隧道**（目标 iOS/iPadOS 18.0–27.2 B2）。

/// 通话录音提示音的禁用 / 恢复服务。
enum CallRecordingToneService {

    // MARK: - 目标文件

    /// 一个提示音文件（设备路径 + bundle 内等长静音素材名）。
    struct Tone: Sendable {
        /// 文件名（也是备份文件名）。
        let name: String
        /// 设备上的绝对路径。
        let path: String
        /// bundle 内等长静音素材名（不含扩展名）。
        let resourceName: String
        /// 静音素材扩展名。
        let resourceExtension: String
    }

    /// 提示音所在目录（AirBeep 实测落点）。
    static let directory = "/var/mobile/Library/CallServices/Greetings/default"

    /// 开始录音提示音。
    static let startTone = Tone(
        name: "StartDisclosureWithTone.m4a",
        path: "\(directory)/StartDisclosureWithTone.m4a",
        resourceName: "AirBeepStartSilence",
        resourceExtension: "m4a"
    )

    /// 结束录音提示音。
    static let stopTone = Tone(
        name: "StopDisclosure.caf",
        path: "\(directory)/StopDisclosure.caf",
        resourceName: "AirBeepStopSilence",
        resourceExtension: "caf"
    )

    /// 全部提示音。
    static var allTones: [Tone] { [startTone, stopTone] }

    // MARK: - 状态

    /// 当前提示音状态。
    enum ToneState: Equatable, Sendable {
        /// 原始提示音（未禁用）。
        case original
        /// 已替换为静音。
        case silenced
        /// 读不到提示音文件（未导入配对文件 / 隧道不通 / 版本不支持）—— 不猜。
        case unreachable
    }

    /// 禁用 / 恢复过程中的错误（airlift 自身的错误由 `AirLiftService.AirLiftError` 直接抛出）。
    enum ToneError: Error, LocalizedError, Sendable {
        /// 没有可恢复的备份。
        case noBackup
        /// bundle 内缺少等长静音素材。
        case invalidToneBundle
        /// 写入后读回校验不一致（写入未生效）。
        case verificationFailed(String)
        /// v0.3.646 新增：设备上已是静音、且没有任何备份 ⇒ 无法恢复。
        ///
        /// 这个错误必须**显式存在**：它代表「用户的原始提示音可能已永久丢失」，
        /// 绝不能被「提前返回成功」掩盖。
        /// v0.3.646 新增：回滚失败 ⇒ 设备状态未知。
        ///
        /// 用两个 String 而不是 Error：enum 声明为 Sendable，
        /// 而关联值带 Error 会让 Sendable 合成失败。
        case rollbackFailed(original: String, rollback: String)
        case silentWithoutBackup

        var errorDescription: String? {
            switch self {
            case .noBackup:
                return "没有找到备份，无法恢复.请先执行一次「禁用提示音」以生成备份."
            case .invalidToneBundle:
                return "bundle 内缺少等长静音素材."
            case .verificationFailed(let name):
                return "写入 \(name) 后校验失败（写入未生效）."
            case .rollbackFailed(let original, let rollback):
                return "操作失败，且回滚也失败（设备上的提示音状态未知）."
                    + "原因：\(original)；回滚失败：\(rollback)."
                    + "请重新打开本页读取真实状态，不要重复操作."
            case .silentWithoutBackup:
                return "设备上的提示音已经是静音，且本机没有备份 —— 无法恢复原始提示音."
                    + "这种情况发生在：禁用后删除/重装过 App，或备份被清理."
                    + "可通过 iTunes/iOS 还原或重新刷机恢复系统默认提示音."
            }
        }
    }

    /// 持久化标记键（用户级）.
    static let disabledKey = "CallRecordingTone.disabled"
    /// 备份目录名（App Documents 下）.
    static let backupDirectoryName = "CallRecordingToneBackup"

    /// 备份目录：Documents/CallRecordingToneBackup。
    static var backupDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
    }

    // MARK: - 状态查询

    /// 查询当前状态。
    ///
    /// 先探**可达性**（经 `AirLiftService` 读一次开始提示音）：读不出即 `.unreachable`，
    /// 不拿持久化标记冒充成功。可达时以持久化标记为准（判据说明见文件头「诚实边界」）。
    static func currentState() async -> ToneState {
        do {
            _ = try await AirLiftService.readFile(at: startTone.path)
        } catch {
            return .unreachable
        }
        return UserDefaults.standard.bool(forKey: disabledKey) ? .silenced : .original
    }

    // MARK: - 禁用

    /// 禁用提示音：先备份原始文件（一次性），再把两个提示音替换为等长静音。
    ///
    /// 写入失败时**回滚**到写入前的原始内容（与 AirBeep 的 `applySilentTone` 一致）。
    static func disable() async throws {
        let current = try await readTones()
        let silent = try silentTones()

        // ⚠️⚠️ v0.3.646 修致命缺陷：**备份必须在任何「提前返回」之前建立**。
        //
        // 原实现是：
        //     if current == silent {
        //         UserDefaults.set(true, ...)   // ← 标记成「已禁用」
        //         return                        // ← **但没建备份**
        //     }
        //     try ensureBackup(current)
        //
        // 于是只要设备上的提示音**已经是静音**（上一次禁用后没恢复、或用户自己换过、
        // 或某个 iOS 版本默认就是静音），第一次点「禁用」就会走这条分支：
        //   · 标记成「已禁用」→ 界面显示「已禁用（静音）」
        //   · **备份从未创建** → 点「恢复」永远报「没有找到备份，无法恢复」
        //   ⇒ 用户的原始提示音**永久丢失**，且 UI 看起来一切正常。
        //
        // 这正是用户报的「严重 bug」。
        //
        // 现在的策略：**无论如何先尝试备份**。ensureBackup 内部已经处理了
        // 「当前内容 == 静音素材」的情况（它拒绝把静音当原始音备份，抛 noBackup），
        // 所以我们把那次判定改成「警告但不阻断」—— 见下面的处理。
        let alreadySilent = (current == silent)
        do {
            try ensureBackup(current)
        } catch ToneError.noBackup {
            // 当前已是静音且无既有备份 ⇒ 无法建立有意义的备份。
            // 这时**不能**静默成功（那会让用户以为可恢复），必须如实告知。
            if alreadySilent {
                throw ToneError.silentWithoutBackup
            }
            throw ToneError.noBackup
        }

        if alreadySilent {
            // 有备份、内容已是静音：只需补标记，无需重写（避免无谓写入）。
            UserDefaults.standard.set(true, forKey: disabledKey)
            return
        }

        do {
            try await writeTones(silent)
            UserDefaults.standard.set(true, forKey: disabledKey)
        } catch {
            // v0.3.646：回滚失败时**必须如实告知**，不能静默吞掉。
            //
            // 原实现是 `try? await writeTones(current)` —— 回滚失败时错误被吞，
            // 调用方只看到「写入失败」，于是界面回到「原始提示音」状态；
            // 而设备上可能是**静音**（写成功一半）或**半新半旧**。
            // ⇒ 用户以为没事，实际提示音状态与 App 显示完全相反。
            //
            // 现在：回滚失败时抛出带说明的错误，让用户知道「状态未知，请重新读状态」。
            do {
                try await writeTones(current)
            } catch let rollbackError {
                throw ToneError.rollbackFailed(original: "(error.localizedDescription)",
                                             rollback: "(rollbackError.localizedDescription)")
            }
            throw error
        }
    }

    // MARK: - 恢复

    /// 从备份恢复原始提示音。
    ///
    /// v0.3.646：备份不存在时，**先分清「设备上是什么」再报错**。
    ///
    /// 原实现不管三七二十一抛 `noBackup`，文案是「请先执行一次禁用提示音以生成备份」。
    /// 这句提示在「设备上已经是静音、但备份丢了」的场景下是**有害的**：
    /// 用户照着做 → 再禁一次 → `disable()` 看到已是静音 → 补标记返回「成功」
    /// ⇒ 用户以为恢复了，其实系统文件还是静音，而且**永远**拿不回来了。
    ///
    /// 现在：设备上是静音、无备份 ⇒ 抛 `silentWithoutBackup`（如实说「可能已永久丢失」）；
    /// 设备上是原始音、无备份 ⇒ 抛 `noBackup`（确实是还没禁用过，建议合理）。
    static func restore() async throws {
        let backup: [Data]
        do {
            backup = try readBackups()
        } catch ToneError.noBackup {
            let current = (try? await readTones()) ?? []
            let silent = (try? silentTones()) ?? []
            if !current.isEmpty, current == silent {
                throw ToneError.silentWithoutBackup
            }
            throw ToneError.noBackup
        }

        let current = try await readTones()
        if current == backup {
            UserDefaults.standard.set(false, forKey: disabledKey)
            return
        }

        do {
            try await writeTones(backup)
            UserDefaults.standard.set(false, forKey: disabledKey)
        } catch {
            // v0.3.646：同上，回滚失败必须如实告知。
            do {
                try await writeTones(current)
            } catch let rollbackError {
                throw ToneError.rollbackFailed(original: "(error.localizedDescription)",
                                             rollback: "(rollbackError.localizedDescription)")
            }
            throw error
        }
    }

    // MARK: - 读 / 写（经 airlift）

    /// 逐个读回两个提示音（airlift 的读是**单文件**原语，故读两次）。
    private static func readTones() async throws -> [Data] {
        var tones: [Data] = []
        tones.reserveCapacity(allTones.count)
        for tone in allTones {
            tones.append(try await AirLiftService.readFile(at: tone.path))
        }
        return tones
    }

    /// 一次 airlift 操作写入两个提示音，随后**读回校验**。
    private static func writeTones(_ tones: [Data]) async throws {
        let payload = zip(allTones, tones).map {
            AirliftToneFile(name: $0.name, data: $1)
        }
        try await AirLiftService.placeFiles(payload, in: directory)

        let verified = try await readTones()
        for (index, tone) in allTones.enumerated() {
            guard verified.indices.contains(index), verified[index] == tones[index] else {
                throw ToneError.verificationFailed(tone.name)
            }
        }
    }

    // MARK: - 备份

    /// 确保两个原始提示音都已备份到 App Documents（已存在则不覆盖）。
    private static func ensureBackup(_ current: [Data]) throws {
        if (try? readBackups()) != nil {
            return
        }
        // 从未改过（当前内容 == 静音素材）时不应建立「备份」，否则会把静音当原始音备份。
        guard current != (try? silentTones()) else {
            throw ToneError.noBackup
        }

        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        for (tone, data) in zip(allTones, current) {
            try data.write(to: backupURL(for: tone), options: .atomic)
        }
    }

    /// 读回已备份的原始提示音（缺任一份即视为无备份）。
    private static func readBackups() throws -> [Data] {
        try allTones.map { tone in
            let url = backupURL(for: tone)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToneError.noBackup
            }
            return try Data(contentsOf: url)
        }
    }

    private static func backupURL(for tone: Tone) -> URL {
        backupDirectory.appendingPathComponent(tone.name)
    }

    // MARK: - 静音素材

    /// 读 bundle 内两个**等长静音**素材。
    private static func silentTones() throws -> [Data] {
        try allTones.map { tone in
            guard let url = resourceURL(for: tone) else {
                throw ToneError.invalidToneBundle
            }
            return try Data(contentsOf: url)
        }
    }

    /// 定位 bundle 内静音素材。
    ///
    /// 依次尝试：bundle 根目录（`Resources/` 递归资源会被平铺到根）、`Resources/` 子目录、
    /// `SilentTones/` 子目录（若改为 folder reference 保留目录时命中）—— 覆盖两种打包方式。
    private static func resourceURL(for tone: Tone) -> URL? {
        let bundle = Bundle.main
        return bundle.url(forResource: tone.resourceName, withExtension: tone.resourceExtension)
            ?? bundle.url(
                forResource: tone.resourceName,
                withExtension: tone.resourceExtension,
                subdirectory: "Resources"
            )
            ?? bundle.url(
                forResource: tone.resourceName,
                withExtension: tone.resourceExtension,
                subdirectory: "SilentTones"
            )
    }
}
