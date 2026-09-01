//
//  PiPKeepAliveService.swift
//  EscapeSpace
//
//  PiP（画中画）保活引擎（v0.3.48）。
//  技术来源：GlobalRefresh-PiP 的 AVPictureInPictureController 方案——
//  应用启动一个循环播放的本地视频并进入画中画，系统在 PiP 存续期间
//  不挂起宿主进程，从而实现比静默音频更强的后台保活。
//
//  视频资产不随包分发：首次启用时用 AVAssetWriter 生成一段 2 秒纯黑
//  H.264 视频（约 3KB），缓存到 Documents/pip_loop.mp4 后无限循环。
//

import AVFoundation
import AVKit
import Foundation
import UIKit

final class PiPKeepAliveService: NSObject, ObservableObject {
    static let shared = PiPKeepAliveService()

    /// 对 UI 发布状态
    @Published private(set) var isPiPActive = false
    @Published private(set) var lastError: String?

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var endObserver: NSObjectProtocol?

    /// 视频缓存路径
    private var videoURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/pip_loop.mp4")
    }

    private override init() {
        super.init()
        // 需要后台音频模式（Info.plist 已含 UIBackgroundModes=audio）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: 生命周期

    /// 绑定一个承载 playerLayer 的宿主视图（必须仍在视图层级中，可小不可无）。
    func attach(layerHost: UIView) {
        let layer = ensurePlayerLayer()
        layer.frame = layerHost.bounds
        layer.videoGravity = .resizeAspect
        // 清掉旧的，挂新的
        layerHost.layer.sublayers?.filter { $0 is AVPlayerLayer }.forEach { $0.removeFromSuperlayer() }
        layerHost.layer.addSublayer(layer)
    }

    /// KVO：等待 isPictureInPicturePossible 变 true（原版 PiP 的关键——
    /// layer 入窗 + item ready 后 possible 才异步置 true，不能同步判一次就放弃）
    private var possibleObservation: NSKeyValueObservation?
    private var startWatchdog: DispatchWorkItem?

    func start() {
        guard let pip = ensurePiPController() else {
            lastError = "设备不支持画中画（AVPictureInPictureController 不可用）"
            return
        }
        if pip.isPictureInPictureActive { return }

        // 视频先播起来（PiP 需要 item 处于播放态）
        player?.play()
        lastError = nil

        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            return
        }

        // 等待 possible → 自动启动（6 秒看门狗）
        possibleObservation?.invalidate()
        possibleObservation = pip.observe(
            \.isPictureInPicturePossible, options: [.new]
        ) { [weak self] observed, _ in
            guard let self, observed.isPictureInPicturePossible else { return }
            DispatchQueue.main.async {
                self.possibleObservation?.invalidate()
                self.possibleObservation = nil
                self.startWatchdog?.cancel()
                self.startWatchdog = nil
                if !(observed.isPictureInPictureActive) {
                    self.player?.play()
                    observed.startPictureInPicture()
                }
            }
        }
        startWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.possibleObservation?.invalidate()
            self.possibleObservation = nil
            if !(self.pipController?.isPictureInPictureActive ?? false) {
                self.lastError = "画中画 6 秒内未就绪——请确认本页面停留（playerLayer 需在窗口层级）后重试"
            }
        }
        startWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: watchdog)
    }

    func stop() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        startWatchdog?.cancel()
        startWatchdog = nil
        pipController?.stopPictureInPicture()
        player?.pause()
    }

    // MARK: 内部

    private func ensurePlayer() -> AVPlayer {
        if let player { return player }
        let url = ensureVideoAsset()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        // 无限循环：播完 seek 回 0 再播（AVPlayerLooper 对 PiP 场景兼容性一般，手动循环最稳）
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerDidEnd),
            name: .AVPlayerItemDidPlayToEndTime, object: item)
        player = p
        return p
    }

    @objc private func playerDidEnd() {
        player?.seek(to: .zero)
        player?.play()
    }

    private func ensurePlayerLayer() -> AVPlayerLayer {
        if let playerLayer { return playerLayer }
        let layer = AVPlayerLayer(player: ensurePlayer())
        playerLayer = layer
        return layer
    }

    private func ensurePiPController() -> AVPictureInPictureController? {
        if let pipController { return pipController }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        let pip = AVPictureInPictureController(playerLayer: ensurePlayerLayer())
        pip?.delegate = self
        // 失效时自动回退，尽量保持 PiP 存活
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = pip
        return pipController
    }

    // MARK: 视频资产生成（AVAssetWriter 纯黑 2s）

    private func ensureVideoAsset() -> URL {
        let url = videoURL
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let size = CGSize(width: 320, height: 180)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            lastError = "生成保活视频失败：\(error.localizedDescription)"
            print("[PiP] \(lastError!)")
            return url
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ])

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 12
        let seconds: Int32 = 2
        var frame = 0
        while input.isReadyForMoreMediaData && frame < fps * seconds {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(
                nil, adaptor.pixelBufferPool!, &pb)
            if let buffer = pb {
                // 纯黑帧（可保持 alpha=255 避免编码异常）
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    memset(base, 0, CVPixelBufferGetDataSize(buffer))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let pts = CMTime(value: CMTimeValue(frame), timescale: fps)
                adaptor.append(buffer, withPresentationTime: pts)
            }
            frame += 1
        }
        input.markAsFinished()
        writer.finishWriting { }
        print("[PiP] 生成保活视频: \(url.path) frames=\(frame)")
        return url
    }
}

extension PiPKeepAliveService: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {}
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isPiPActive = true }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isPiPActive = false }
    }
    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }
}
