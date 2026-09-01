//
//  PiPKeepAliveService.swift
//  EscapeSpace
//
//  PiP（画中画）保活引擎 v3（v0.3.56）——GlobalRefresh 原版忠实移植：
//
//  结构（与原版 setupPiPSourceView / setupPip / requestPiPStartWhenReady 一一对应）：
//   - pipSourceView：clear 背景 + 圆角18 + 不可交互，加入宿主层级（frame 归本服务管）
//   - videoCallContentController：AVPictureInPictureVideoCallViewController，
//     view 背景全 clear（原版同款），内嵌实际内容视图（原版为时钟层，此处为保活标签）
//   - ContentSource(activeVideoCallSourceView:contentViewController:) + requiresLinearPlayback
//     + canStartPictureInPictureAutomaticallyFromInline
//   - 启动：原版 requestPiPStartWhenReady 同款重试循环
//     （sourceReady = bounds 非空 && window 非空；possible 检查；最多 8 次×0.35s）
//   - 音频会话：.playback + .mixWithOthers + setActive（原版 playbackActive：
//     "start with active playback so PiP is possible immediately"）
//   - 隐藏：原版 preparePiPVisualSurfacesForClosing 三件套
//     （preferredContentSize 1x1 + view alpha 0.01/背景 clear + 源视图同步缩放）
//   - PiP 期间持有 background task（原版 "PiPKeepAlive"）；意外停止自动恢复
//

import AVFoundation
import AVKit
import Foundation
import UIKit

final class PiPKeepAliveService: NSObject, ObservableObject {
    static let shared = PiPKeepAliveService()

    @Published private(set) var isPiPActive = false
    @Published private(set) var isHidden = false
    @Published private(set) var lastError: String?
    /// PiP 启动时刻（运行时长由 TimelineView 据此计算，跨页面存活）
    @Published private(set) var startedAt: Date?

    private var pipController: AVPictureInPictureController?
    private var videoCallContentController: AVPictureInPictureVideoCallViewController?
    /// 源视图（原版强持有，非 weak）
    private var pipSourceView: UIView?
    /// SwiftUI 布局宿主
    private weak var hostContainer: UIView?

    private var possibleObservation: NSKeyValueObservation?
    private var pendingStartWork: DispatchWorkItem?
    private var intentionalStop = false
    private var autoRestoreRemaining = 5
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var clockLabel: UILabel?
    private var clockTimer: Timer?

    private func updateClockLabel() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        clockLabel?.text = f.string(from: Date())
    }

    // 原版高度系统常量（videoCall 路线）
    static let textPiPWidth: CGFloat = 300
    static let minPiPHeight: CGFloat = 0.1
    static let maxPiPHeight: CGFloat = 220
    static let piPHeightStep: CGFloat = 0.1
    static let defaultPiPHeight: CGFloat = 120

    static let hiddenSize = CGSize(width: textPiPWidth, height: minPiPHeight)
    static var normalSize: CGSize { CGSize(width: textPiPWidth, height: defaultPiPHeight) }

    /// 用户可调高度（0.1~220，步进 0.1，记忆到 UserDefaults）
    @Published var pipHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "pip.height")
        if saved >= 0.1 && saved <= 220 { return saved }
        return defaultPiPHeight
    }() {
        didSet {
            let clamped = clampedHeight(pipHeight)
            if clamped != pipHeight { pipHeight = clamped }
        }
    }

    /// 滑杆/外部设置高度入口：夹紧 → 存储 → 异步应用（避开 SwiftUI 更新事务内改 UIKit）
    func setHeight(_ h: CGFloat) {
        pipHeight = clampedHeight(h)
        UserDefaults.standard.set(pipHeight, forKey: "pip.height")
        DispatchQueue.main.async { [weak self] in
            self?.applyCurrentSize()
        }
    }

    private func clampedHeight(_ h: CGFloat) -> CGFloat {
        let stepped = (h / Self.piPHeightStep).rounded() * Self.piPHeightStep
        return min(max(stepped, Self.minPiPHeight), Self.maxPiPHeight)
    }

    private var currentSize: CGSize {
        isHidden ? Self.hiddenSize : CGSize(width: Self.textPiPWidth, height: pipHeight)
    }

    /// 把当前尺寸同步到 contentVC + 源视图（原版 currentPiPSize 应用点）
    private func applyCurrentSize() {
        let size = currentSize
        videoCallContentController?.preferredContentSize = size
        pipSourceView?.frame.size = size
    }

    private override init() {
        super.init()
    }

    // MARK: 源视图（原版 setupPiPSourceView）

    /// 绑定宿主容器：把 pipSourceView 加进真实窗口层级（原版 view.addSubview 同款）
    func attach(hostContainer: UIView) {
        self.hostContainer = hostContainer
        if pipSourceView == nil {
            let v = UIView()
            v.backgroundColor = .clear
            v.isOpaque = false
            v.isUserInteractionEnabled = false
            v.layer.cornerRadius = 18
            v.layer.cornerCurve = .continuous
            v.clipsToBounds = true
            hostContainer.addSubview(v)
            pipSourceView = v
        }
        pipSourceView?.frame = CGRect(origin: .zero,
                                      size: CGSize(width: Self.textPiPWidth, height: pipHeight))
    }

    // MARK: PiP 构建（原版 setupPip videoCall 分支）

    private func setupPiP() {
        guard videoCallContentController == nil, let src = pipSourceView else { return }

        let contentController = AVPictureInPictureVideoCallViewController()
        contentController.preferredContentSize = Self.normalSize
        contentController.view.backgroundColor = .clear
        contentController.view.isOpaque = false
        contentController.view.layer.backgroundColor = UIColor.clear.cgColor
        contentController.view.layer.isOpaque = false
        contentController.view.clipsToBounds = true

        // 原版 attachCustomViewToPiPContent：contentVC 内必须有实际内容视图
        let contentView = UIView()
        contentView.backgroundColor = UIColor(white: 0.07, alpha: 1)
        contentView.frame = CGRect(origin: .zero, size: Self.normalSize)
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let label = UILabel()
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        contentController.view.addSubview(contentView)
        // 原版 clock mode：画中画内实时时钟（1s 刷新）
        clockLabel = label
        clockTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClockLabel()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
        updateClockLabel()

        videoCallContentController = contentController

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: src,
            contentViewController: contentController
        )
        let pip = AVPictureInPictureController(contentSource: contentSource)
        pip.delegate = self
        pip.requiresLinearPlayback = true
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = pip
    }

    // MARK: 启动（原版 requestPiPStartWhenReady 重试循环）

    func start() {
        // 原版 playbackActive 路线：先激活音频会话，PiP 立即可用
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)

        intentionalStop = false
        autoRestoreRemaining = 5
        lastError = nil

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            lastError = "设备不支持画中画"
            return
        }
        guard hostContainer?.window != nil else {
            lastError = "源视图不在窗口层级——请停留在本页面后重试"
            return
        }
        setupPiP()
        requestStart(attempt: 1)
    }

    private func requestStart(attempt: Int) {
        guard let pip = pipController, let src = pipSourceView else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pip = self.pipController, let src = self.pipSourceView else { return }
            // 原版同款检查：源就绪（bounds 非空 && window 非空）+ possible
            let sourceReady = !src.bounds.isEmpty && src.window != nil
            let canStartNow = sourceReady && pip.isPictureInPicturePossible
            if canStartNow {
                pip.startPictureInPicture()
                self.beginBackgroundTaskIfNeeded()
                return
            }
            if attempt <= 8 {
                self.pendingStartWork?.cancel()
                self.requestStart(attempt: attempt + 1)
            } else {
                self.lastError = "画中画暂时不可启动：possible=\(pip.isPictureInPicturePossible), sourceReady=\(sourceReady)"
            }
        }
        pendingStartWork?.cancel()
        pendingStartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 1 ? 0.05 : 0.35), execute: work)
    }

    func stop() {
        intentionalStop = true
        pendingStartWork?.cancel()
        pipController?.stopPictureInPicture()
        endBackgroundTaskIfNeeded()
    }

    // MARK: 隐藏 / 显示（原版 preparePiPVisualSurfacesForClosing / restorePiPVisualSurfaces）

    func hide() {
        guard let vc = videoCallContentController else { return }
        UIView.performWithoutAnimation {
            pipSourceView?.frame.size = Self.hiddenSize
            vc.preferredContentSize = Self.hiddenSize
            vc.view.backgroundColor = .clear
            vc.view.layer.backgroundColor = UIColor.clear.cgColor
            vc.view.alpha = 0.01
            pipSourceView?.alpha = 0.01
            hostContainer?.layoutIfNeeded()
            CATransaction.flush()
        }
        isHidden = true
    }

    func show() {
        guard let vc = videoCallContentController else { return }
        UIView.performWithoutAnimation {
            applyCurrentSize()
            vc.view.alpha = 1
            vc.view.backgroundColor = .clear
            pipSourceView?.alpha = 1
            hostContainer?.layoutIfNeeded()
        }
        isHidden = false
    }

    // MARK: 后台任务（原版 beginBackgroundTaskIfNeeded "PiPKeepAlive"）

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PiPKeepAlive") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension PiPKeepAliveService: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {}

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = true
            self.isHidden = false
            if self.startedAt == nil { self.startedAt = Date() }
            self.beginBackgroundTaskIfNeeded()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false
            self.startedAt = nil
            // 意外停止自动恢复（系统杀 PiP → 拉起；用户点「停止」不恢复）
            if !self.intentionalStop && self.autoRestoreRemaining > 0 {
                self.autoRestoreRemaining -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, !(self.pipController?.isPictureInPictureActive ?? true) else { return }
                    print("[PiP] 意外停止，自动恢复（剩余 \(self.autoRestoreRemaining) 次）")
                    self.start()
                }
            } else if self.intentionalStop {
                self.endBackgroundTaskIfNeeded()
            }
        }
    }

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }
}
