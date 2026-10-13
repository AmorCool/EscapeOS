import Foundation
import AVFoundation

// MARK: - 禁用通话录音提示音（参考项目 AirBeep）
//
// ## 原理（来自 AirBeep / 原名 Placard，仓库 `LinkPass888/AirBeep`）
// 通话录音开始 / 结束时会播放一段**披露提示音**（disclosure tone），文件落在
// `/var/mobile/Library/CallServices/Greetings/default/`：
//   · 开始：`StartDisclosureWithTone.m4a` —— AAC 44.1 kHz 单声道，1.834 s
//   · 结束：`StopDisclosure.caf`          —— PCM s16le 48 kHz 单声道，1.770 s
// AirBeep 的做法：把这两个文件**替换成等长静音**（时长、容器、采样率一致，只是内容全零）。
// 系统照常播放「一个文件」，只是听不到提示音；**录音本身不受影响**。
//
// ## 本仓怎么落地
// 替换写入经 `SandboxFileAccess`（设备侧任意路径文件访问原语）—— 它走**设备上真正
// 可用的漏洞利用**（默认 `bad_query`）取沙盒扩展，**不依赖 AirLift**。
// 原始提示音在首次禁用时**备份到 App 自己的 Documents**，可一键恢复。
//
// ## 诚实边界
// · 生成静音用的是 AVFoundation（`AVAudioFile`）：`.caf` 走 PCM 直写（可靠），
//   `.m4a` 走 AAC 编码（iOS 内置编码器）。**本机（Windows）无法编译 / 实机验证**，
//   格式与时长按研究结论钉死，实机行为待真机复测。
// · 状态判据用持久化标记（`UserDefaults`）而非文件内容比对 —— 因为 PCM 静音与 PCM 原音
//   **长度相同、字节数也相同**，按大小无法区分；故如实说明「状态以本 App 的标记为准」。
// · 写入需先在「更多 → 漏洞利用」启用可用的漏洞利用（默认 `bad_query` 即可）。

/// 通话录音提示音的禁用 / 恢复服务。
enum CallRecordingToneService {

    // MARK: - 目标文件

    /// 一个提示音文件（路径 + 时长 + 容器格式）。
    struct Tone: Sendable {
        /// 容器 / 编码类型 —— 决定生成静音时用哪种写法。
        enum Container: Sendable {
            /// AAC（.m4a），走编码器。
            case aacM4A
            /// 线性 PCM（.caf），直写。
            case pcmCAF
        }

        /// 文件名（也是备份文件名）。
        let name: String
        /// 设备上的绝对路径。
        let path: String
        /// 时长（秒）—— 与原始提示音一致，保证替换后「等长」。
        let duration: Double
        let container: Container

        /// 文件扩展名（决定 AVAudioFile 的容器）。
        var pathExtension: String { (name as NSString).pathExtension }
    }

    /// 提示音所在目录（AirBeep 实测落点）。
    static let directory = "/var/mobile/Library/CallServices/Greetings/default"

    /// 开始录音提示音。
    static let startTone = Tone(
        name: "StartDisclosureWithTone.m4a",
        path: "\(directory)/StartDisclosureWithTone.m4a",
        duration: 1.834,
        container: .aacM4A
    )

    /// 结束录音提示音。
    static let stopTone = Tone(
        name: "StopDisclosure.caf",
        path: "\(directory)/StopDisclosure.caf",
        duration: 1.770,
        container: .pcmCAF
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
        /// 读不到提示音文件（未启用可用漏洞利用 / 路径不可达）—— 不猜。
        case unreachable
    }

    /// 禁用 / 恢复过程中的错误。
    enum ToneError: Error, LocalizedError, Sendable {
        /// 没有可恢复的备份。
        case noBackup
        /// AVFoundation 无法构造所需的音频格式 / 缓冲区。
        case audioFormatUnavailable
        case audioBufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .noBackup:
                return "没有找到备份，无法恢复.请先执行一次「禁用提示音」以生成备份."
            case .audioFormatUnavailable:
                return "无法构造所需的音频格式（设备可能不支持该采样率 / 编码）."
            case .audioBufferAllocationFailed:
                return "无法分配静音音频缓冲区."
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
    /// 先探**可达性**（经 `SandboxFileAccess` 读一次开始提示音）：读不出即 `.unreachable`，
    /// 不拿持久化标记冒充成功。可达时以持久化标记为准（判据说明见文件头「诚实边界」）。
    static func currentState() -> ToneState {
        do {
            _ = try SandboxFileAccess.readFile(at: startTone.path)
        } catch {
            return .unreachable
        }
        return UserDefaults.standard.bool(forKey: disabledKey) ? .silenced : .original
    }

    // MARK: - 禁用

    /// 禁用提示音：先备份原始文件（一次性），再把两个提示音替换为等长静音。
    static func disable() throws {
        try ensureBackup()
        for tone in allTones {
            let silent = try silentData(for: tone)
            try SandboxFileAccess.placeFile(silent, at: tone.path)
        }
        UserDefaults.standard.set(true, forKey: disabledKey)
    }

    // MARK: - 恢复

    /// 从备份恢复原始提示音。
    static func restore() throws {
        let fm = FileManager.default
        var restored = 0
        for tone in allTones {
            let backup = backupDirectory.appendingPathComponent(tone.name)
            guard fm.fileExists(atPath: backup.path) else { continue }
            let data = try Data(contentsOf: backup)
            try SandboxFileAccess.placeFile(data, at: tone.path)
            restored += 1
        }
        guard restored > 0 else { throw ToneError.noBackup }
        UserDefaults.standard.set(false, forKey: disabledKey)
    }

    // MARK: - 备份

    /// 确保两个原始提示音都已备份到 App Documents（已存在则不覆盖）。
    static func ensureBackup() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        for tone in allTones {
            let backup = backupDirectory.appendingPathComponent(tone.name)
            guard !fm.fileExists(atPath: backup.path) else { continue }
            let data = try SandboxFileAccess.readFile(at: tone.path)
            try data.write(to: backup, options: .atomic)
        }
    }

    // MARK: - 静音生成

    /// 生成与原始提示音**等长同格式**的静音数据。
    static func silentData(for tone: Tone) throws -> Data {
        let fm = FileManager.default
        let url = fm.temporaryDirectory
            .appendingPathComponent("silence-\(UUID().uuidString).\(tone.pathExtension)")
        defer { try? fm.removeItem(at: url) }

        switch tone.container {
        case .pcmCAF:
            try writeSilentPCM(to: url, sampleRate: 48_000, duration: tone.duration)
        case .aacM4A:
            try writeSilentAAC(to: url, sampleRate: 44_100, duration: tone.duration)
        }
        return try Data(contentsOf: url)
    }

    /// 写一个 PCM（16-bit 线性，单声道）静音 `.caf`。
    private static func writeSilentPCM(to url: URL,
                                       sampleRate: Double,
                                       duration: Double) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: true) else {
            throw ToneError.audioFormatUnavailable
        }
        let frames = AVAudioFrameCount((sampleRate * duration).rounded())
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ToneError.audioBufferAllocationFailed
        }
        // AVAudioPCMBuffer 分配即全零 ⇒ 内容就是静音，无需再填。
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    /// 写一个 AAC 静音 `.m4a`（44.1 kHz 单声道，与原始提示音同参数）。
    private static func writeSilentAAC(to url: URL,
                                       sampleRate: Double,
                                       duration: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        // 处理格式由输出设置推导（AAC 的处理格式为 float32 非交错）——用它保证缓冲区匹配。
        let format = file.processingFormat
        let frames = AVAudioFrameCount((sampleRate * duration).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ToneError.audioBufferAllocationFailed
        }
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}
