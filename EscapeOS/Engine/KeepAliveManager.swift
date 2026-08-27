import AVFoundation
import Foundation

/// 后台保活（汉化移植自 rooootdev/mond 的 keepalive.swift，MIT）。
///
/// 机制：申请 `AVAudioSession` playback 类别（mixWithOthers 不打断他人音频），
/// 循环播放一段 0.5 秒静音 WAV——iOS 认为应用正在播放音频，配合
/// Info.plist 的 `UIBackgroundModes: audio`，进程退后台后不会被挂起，
/// 让虚拟定位的重发/心跳定时器与配对广播等持续任务继续运行。
///
/// 用法：
/// - 「更多 → 设置 → 保活」开关控制 `isEnabled`（UserDefaults 持久化）；
/// - 虚拟定位激活时调用 `ensureRunning()`（强制保活，与开关无关），
///   停止模拟后调用 `stopIfNotRequested()`（开关关闭时自动停）。
final class KeepAliveManager {
    static let shared = KeepAliveManager()

    /// 设置页开关的持久化键。
    static let enabledKey = "KeepAliveEnabled"

    private var player: AVAudioPlayer?
    private var timer: Timer?
    /// 虚拟定位等任务强制保活时置位；停止任务后若开关关闭则真正停止。
    private var forced = false

    private init() {}

    /// 设置页开关当前值。
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// 是否正在保活。
    var isRunning: Bool { player != nil }

    /// 启动保活（幂等）。`force` 用于虚拟定位等必须保活的场景。
    func start(force: Bool = false) {
        if force { forced = true }
        guard player == nil else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            let wav = try Self.silentWAV()
            let p = try AVAudioPlayer(data: wav)
            p.volume = 0
            p.numberOfLoops = -1
            p.play()
            player = p

            // 兜底：部分系统在锁屏/后台偶发暂停，定时补播。
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let p = self.player else { return }
                if !p.isPlaying { p.play() }
            }
        } catch {
            NSLog("[KeepAlive] 启动失败: %@", error.localizedDescription)
        }
    }

    /// 停止保活。若 `force` 保活仍有效（虚拟定位还在跑），调用后不会真正停止。
    func stop() {
        forced = false
        stopIfNotRequested()
    }

    /// 仅当没有被强制保活且设置开关关闭时真正停止。
    func stopIfNotRequested() {
        guard !forced, !isEnabled else { return }
        stopNow()
    }

    /// 强制保活（虚拟定位激活时调用，幂等）。
    func ensureRunning() {
        start(force: true)
    }

    private func stopNow() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 生成 0.5 秒静音 WAV（8000 Hz 16-bit 单声道 PCM）。
    private static func silentWAV() throws -> Data {
        let sr = 8000, samples = Int(Double(sr) * 0.5)
        var w = Data("RIFF".utf8)
        w += withUnsafeBytes(of: UInt32(36 + samples * 2).littleEndian) { Data($0) }
        w += Data("WAVEfmt ".utf8)
        w += withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }
        w += withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }
        w += withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }
        w += withUnsafeBytes(of: UInt32(sr).littleEndian) { Data($0) }
        w += withUnsafeBytes(of: UInt32(sr * 2).littleEndian) { Data($0) }
        w += withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) }
        w += withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) }
        w += Data("data".utf8)
        w += withUnsafeBytes(of: UInt32(samples * 2).littleEndian) { Data($0) }
        w += Data(count: samples * 2)
        return w
    }
}
