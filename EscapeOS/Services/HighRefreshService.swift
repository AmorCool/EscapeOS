//
//  HighRefreshService.swift
//  EscapeSpace
//
//  全局高刷（v0.3.51）——移植自 GlobalRefresh 的帧率方案：
//  持续调度的 CADisplayLink 携带 preferredFrameRateRange(30, max, max)，
//  迫使系统在 app 活跃期间维持最高刷新率（ProMotion 120Hz）。
//  关闭时 preferred 回 0 交还系统自适应，不干涉其它场景。
//

import Foundation
import QuartzCore
import UIKit

final class HighRefreshService: NSObject, ObservableObject {
    static let shared = HighRefreshService()

    @Published private(set) var isRunning = false
    /// 实测帧率（每秒采样一次）
    @Published private(set) var measuredFPS: Int = 0

    private var displayLink: CADisplayLink?
    private var frameCount = 0
    private var lastSample: CFTimeInterval = 0

    /// 设备屏幕最大刷新率（60 / 120）
    var maxFPS: Int { Int(UIScreen.main.maximumFramesPerSecond) }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            // 原版同款：min 30 / max+preferred 设备上限
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30,
                maximum: Float(maxFPS),
                preferred: Float(maxFPS))
        } else {
            link.preferredFramesPerSecond = maxFPS
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        frameCount = 0
        lastSample = 0
        isRunning = true
        print("[HighRefresh] 已启动 目标=\(maxFPS)Hz")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
        measuredFPS = 0
        print("[HighRefresh] 已停止")
    }

    @objc private func tick() {
        frameCount += 1
        let now = CACurrentMediaTime()
        if lastSample == 0 { lastSample = now; return }
        let elapsed = now - lastSample
        if elapsed >= 1.0 {
            measuredFPS = Int((Double(frameCount) / elapsed).rounded())
            frameCount = 0
            lastSample = now
        }
    }
}
