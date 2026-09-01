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

    private var pipController: AVPictureInPictureController?
    private var contentVC: UIViewController?
    /// 在窗口层级内的源视图（启动 PiP 的前提；PiP 启动后可离开页面）
    private weak var sourceView: UIView?

    /// PiP 内容尺寸（隐藏 = 0.1x0.1，原版 0.1pt 技巧）
    static let normalSize = CGSize(width: 320, height: 180)
    static let hiddenSize = CGSize(width: 0.1, height: 0.1)

    /// 意外停止自动恢复（系统杀 PiP 时自动重启，最多 5 次）
    private var autoRestoreRemaining = 5
    private var intentionalStop = false

    /// KVO：等待 isPictureInPicturePossible（异步置 true，原版同款）
    private var possibleObservation: NSKeyValueObservation?
    private var startWatchdog: DispatchWorkItem?

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    // MARK: 源视图绑定

    /// 绑定在窗口层级内的宿主视图（页面内的预览小窗即可）
    func attach(sourceView: UIView) {
        self.sourceView = sourceView
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
            pipController = pip
            contentVC = vc
        }
        guard let pip = pipController else { return }

        // 音频会话激活（后台保活加成）
        try? AVAudioSession.sharedInstance().setActive(true)
        lastError = nil
        intentionalStop = false

        if pip.isPictureInPictureActive { return }
        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
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
    }

    // MARK: 隐藏 / 显示（preferredContentSize 缩放 PiP 窗口，原版 0.1pt 技巧）

    func hide() {
        contentVC?.preferredContentSize = Self.hiddenSize
        isHidden = true
    }

    func show() {
        contentVC?.preferredContentSize = Self.normalSize
        isHidden = false
    }
}

extension PiPKeepAliveService: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {}
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = true
            self.isHidden = false
        }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isPiPActive = false
            // 意外停止自动恢复（用户手动关 PiP 视为意外——保活语义下自动拉起）
            if !self.intentionalStop && self.autoRestoreRemaining > 0 {
                self.autoRestoreRemaining -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, !(self.pipController?.isPictureInPictureActive ?? true) else { return }
                    print("[PiP] 意外停止，自动恢复（剩余 \(self.autoRestoreRemaining) 次）")
                    self.start()
                }
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
