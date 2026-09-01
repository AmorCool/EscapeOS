//
//  PiPKeepAliveService.swift
//  EscapeSpace
//
//  PiP（画中画）保活引擎 v2（v0.3.50）——对齐 GlobalRefresh 原版方案：
//  默认走 VideoCall ContentSource 路线（非视频）：
//    AVPictureInPictureController.ContentSource(activeVideoCallSourceView:contentViewController:)
//  画中画窗口内显示任意 UIView（纯黑占位），可调节/可隐藏：
//    contentViewController.preferredContentSize = 1x1 → 窗口缩到不可见（原版 0.1pt 技巧）
//    恢复 320x180 → 窗口还原
//  PiP 存续期间系统不挂起宿主进程 → 后台保活。
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
    /// PiP 启动时刻（页面离开再回来时长不归零的关键——由 TimelineView 实时计算）
    @Published private(set) var startedAt: Date?

    private var pipController: AVPictureInPictureController?
    private var contentVC: UIViewController?
    /// SwiftUI 布局宿主（frame 由 SwiftUI 管）
    private weak var hostView: UIView?
    /// 实际 PiP 源视图（frame 由本服务管——videoCall 模式 PiP 窗口尺寸跟随它）
    private weak var sourceView: UIView?

    /// PiP 内容尺寸（隐藏 = 1x1，原版 preparePiPVisualSurfacesForClosing 同款）
    static let normalSize = CGSize(width: 320, height: 180)
    static let hiddenSize = CGSize(width: 1, height: 1)

    /// 意外停止自动恢复（系统杀 PiP 时自动重启，最多 5 次）
    private var autoRestoreRemaining = 5
    private var intentionalStop = false

    /// KVO：等待 isPictureInPicturePossible（异步置 true，原版同款）
    private var possibleObservation: NSKeyValueObservation?
    private var startWatchdog: DispatchWorkItem?

    /// 后台任务桥（原版 beginBackgroundTaskIfNeeded："PiPKeepAlive"）
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

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

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    // MARK: 源视图绑定

    /// 绑定宿主视图 + 内部源视图（源视图 frame 归本服务控制）
    func attach(host: UIView, sourceView: UIView) {
        self.hostView = host
        self.sourceView = sourceView
        // 恢复上次隐藏态的源视图尺寸
        sourceView.frame = CGRect(origin: .zero,
                                  size: isHidden ? Self.hiddenSize : host.bounds.size)
    }

    // MARK: 启停

    func start() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            lastError = "设备不支持画中画"
            return
        }
        guard let src = sourceView, src.window != nil else {
            lastError = "源视图不在窗口层级——请停留在本页面后重试"
            return
        }

        if pipController == nil {
            let vc = AVPictureInPictureVideoCallViewController()
            vc.view.backgroundColor = .black
            vc.preferredContentSize = Self.normalSize
            let source = AVPictureInPictureController.ContentSource(
                activeVideoCallSourceView: src,
                contentViewController: vc)
            let pip = AVPictureInPictureController(contentSource: source)
            pip.delegate = self
            // 原版 updatePiPAutomaticStartPolicy：回后台自动进 PiP
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = pip
            contentVC = vc
        }
        guard let pip = pipController else { return }

        // 原版实锤：.playback + mixWithOthers + setActive——
        // "start with active playback so PiP is possible immediately"
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        lastError = nil
        intentionalStop = false

        if pip.isPictureInPictureActive { return }
        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            beginBackgroundTaskIfNeeded()
            return
        }

        // KVO 等待 possible → 自动启动（6 秒看门狗）
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
                    observed.startPictureInPicture()
                    self.beginBackgroundTaskIfNeeded()
                }
            }
        }
        startWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.possibleObservation?.invalidate()
            self.possibleObservation = nil
            if !(self.pipController?.isPictureInPictureActive ?? false) {
                self.lastError = "画中画 6 秒内未就绪，请重试"
            }
        }
        startWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: watchdog)
    }

    func stop() {
        intentionalStop = true
        possibleObservation?.invalidate()
        possibleObservation = nil
        startWatchdog?.cancel()
        startWatchdog = nil
        pipController?.stopPictureInPicture()
        endBackgroundTaskIfNeeded()
    }

    // MARK: 隐藏 / 显示（preferredContentSize 缩放 PiP 窗口，原版 0.1pt 技巧）

    /// 隐藏（原版 preparePiPVisualSurfacesForClosing 同款三件套：
    /// preferredContentSize 1x1 + 内容视图 alpha 0.01/背景清空 + 强制 layout flush）
    func hide() {
        guard let vc = contentVC else { return }
        UIView.performWithoutAnimation {
            // videoCall 模式 PiP 窗口尺寸跟随源视图——源视图必须一起缩（原版 minPiPHeight 同理）
            sourceView?.frame.size = Self.hiddenSize
            vc.preferredContentSize = Self.hiddenSize
            vc.view.backgroundColor = .clear
            vc.view.layer.backgroundColor = UIColor.clear.cgColor
            vc.view.alpha = 0.01
            sourceView?.alpha = 0.01
            hostView?.layoutIfNeeded()
            CATransaction.flush()
        }
        isHidden = true
    }

    func show() {
        guard let vc = contentVC else { return }
        UIView.performWithoutAnimation {
            sourceView?.frame.size = hostView?.bounds.size ?? Self.normalSize
            vc.preferredContentSize = Self.normalSize
            vc.view.alpha = 1
            vc.view.backgroundColor = .black
            sourceView?.alpha = 1
            hostView?.layoutIfNeeded()
        }
        isHidden = false
    }
}

extension PiPKeepAliveService: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {}
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = true
            self.isHidden = false
            if self.startedAt == nil { self.startedAt = Date() }
        }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false
            self.startedAt = nil
            // 意外停止自动恢复（系统杀 PiP → 自动拉起；用户点「停止」不恢复）
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
