//
//  BackgroundAudioManager.swift
//  EscapeSpace
//
//  后台静默音频保活。移植自 StikPair / StikDebug：
//  通过持续播放 0 音量 PCM 缓冲区并占用 AVAudioSession，
//  使应用在后台/锁屏时仍被系统视为「正在播放音频」，
//  从而延缓 Bonjour 注册被系统 SRP sweeper 回收。
//

import AVFoundation

final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var isRunning = false
    private var persistentEnabled = false
    private var activityCount = 0
    private var healthCheckTimer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    /// 持久开启（无线配对期间调用）。
    func start() {
        persistentEnabled = true
        refreshRunningState()
    }

    /// 持久关闭（配对结束 / sheet 关闭时调用）。
    func stop() {
        persistentEnabled = false
        refreshRunningState()
    }

    /// 临时请求开启（计数器模式）。
    func requestStart() {
        activityCount += 1
        refreshRunningState()
    }

    /// 临时请求关闭。
    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        refreshRunningState()
    }

    private func refreshRunningState() {
        let shouldRun = persistentEnabled || (activityCount > 0 && UserDefaults.standard.bool(forKey: "keepAliveAudio"))
        guard shouldRun != isRunning else {
            if shouldRun {
                recoverIfNeeded()
            }
            return
        }

        isRunning = shouldRun
        if shouldRun {
            startEngine()
            startHealthCheck()
        } else {
            healthCheckTimer?.invalidate()
            healthCheckTimer = nil
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startEngine() {
        do {
            engine.stop()
            player.stop()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)

            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            scheduleSilence()
            try engine.start()
            player.play()
        } catch {
            NSLog("[BackgroundAudioManager] 启动失败: %@", error.localizedDescription)
        }
    }

    private func scheduleSilence() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        // PCM 缓冲区已初始化为 0 —— 纯静音，不耗电也不出声。
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }

    /// 每 2 秒检查一次，若被其他音频会话挤占则重新夺回。
    private func startHealthCheck() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.recoverIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    private func recoverIfNeeded() {
        guard isRunning, !engine.isRunning || !player.isPlaying else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
            player.play()
        } catch {
            // 音频会话仍被占用，下次心跳再试。
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended,
              isRunning else { return }

        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    @objc private func handleMediaServicesReset() {
        guard isRunning else { return }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        startEngine()
    }
}
