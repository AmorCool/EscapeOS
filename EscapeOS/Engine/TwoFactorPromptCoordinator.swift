import Foundation
import SwiftUI

/// 全局 2FA 验证码请求协调器（v0.2.113）。
///
/// ## 背景
/// IPA 侧载的 2FA 由 Rust（isideload）在阻塞线程里发起，原先只有
/// 「IPA 侧载」页注入的 `IPAInstallService.twoFactorPrompt` 能弹窗。
/// 但 App 启动时的后台预热（`RootView.warmUpAutoLogin()` →
/// `IPAInstallService.warmUp()`）发生在用户进入该页**之前**，此时
/// `twoFactorPrompt` 为 nil，2FA 请求被静默丢弃：手机上弹出了 Apple
/// 验证码，App 里却没有输入框，登录随之失败/卡住。
///
/// ## 现在
/// 任何来源（含后台预热）的 2FA 都汇总到这里，由 `RootView` 统一弹出
/// 输入框，标题标明来自哪个功能。
///
/// - Note: 所有方法都必须在**主线程**调用（内部会驱动 SwiftUI 更新）。
///         调用方是 `IPAInstallService.beginTwoFactorPrompt()`，已在
///         `DispatchQueue.main.async` 里，因此天然满足。
final class TwoFactorPromptCoordinator: ObservableObject {

    static let shared = TwoFactorPromptCoordinator()

    /// 一次待用户处理的 2FA 请求。
    struct Request: Identifiable {
        let id = UUID()
        /// 发起请求的功能名（如「IPA 侧载」），显示在弹窗标题里。
        let feature: String
        /// 用户输入后的回调；传 nil 表示用户取消。
        let reply: (String?) -> Void
    }

    /// 当前待处理的请求；非 nil 时 `RootView` 弹出输入框。
    @Published private(set) var pending: Request?

    /// 用户输入的验证码（绑定到弹窗的 TextField）。
    @Published var code: String = ""

    private init() {}

    // MARK: - 请求 / 响应

    /// 请求用户输入 2FA 验证码。
    /// - Parameters:
    ///   - feature: 发起请求的功能名，显示在弹窗标题里。
    ///   - reply: 用户输入后的回调；nil 表示取消。
    func requestCode(from feature: String, reply: @escaping (String?) -> Void) {
        // 已有未处理请求：先取消旧的，避免两个输入框互相覆盖、
        // 也避免旧的阻塞线程永远等不到 signal。
        if let previous = pending {
            previous.reply(nil)
        }
        code = ""
        pending = Request(feature: feature, reply: reply)
    }

    /// 用户点「登录」：把输入回传给等待方。
    func submit() {
        guard let request = pending else { return }
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = nil
        code = ""
        request.reply(value.isEmpty ? nil : value)
    }

    /// 用户点「取消」（或弹窗被系统关闭）。
    func cancel() {
        guard let request = pending else { return }
        pending = nil
        code = ""
        request.reply(nil)
    }
}
