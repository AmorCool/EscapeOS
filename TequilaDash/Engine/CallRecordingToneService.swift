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

        var errorDescription: String? {
            switch self {
            case .noBackup:
                return "没有找到备份，无法恢复.请先执行一次「禁用提示音」以生成备份."
            case .invalidToneBundle:
                return "bundle 内缺少等长静音素材."
            case .verificationFailed(let name):
                return "写入 \(name) 后校验失败（写入未生效）."
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
        if current == silent {
            UserDefaults.standard.set(true, forKey: disabledKey)
            return
        }

        try ensureBackup(current)
        do {
            try await writeTones(silent)
            UserDefaults.standard.set(true, forKey: disabledKey)
        } catch {
            try? await writeTones(current)
            throw error
        }
    }

    // MARK: - 恢复

    /// 从备份恢复原始提示音。
    static func restore() async throws {
        guard let backup = try? readBackups() else { throw ToneError.noBackup }
        let current = try await readTones()
        if current == backup {
            UserDefaults.standard.set(false, forKey: disabledKey)
            return
        }

        do {
            try await writeTones(backup)
            UserDefaults.standard.set(false, forKey: disabledKey)
        } catch {
            try? await writeTones(current)
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
