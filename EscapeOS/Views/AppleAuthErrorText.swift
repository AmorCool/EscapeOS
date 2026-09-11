import SwiftUI

/// v0.3.311：Apple 认证错误文案（原定义在已删除的「App Store 下载」板块里，
/// 该板块整体移除后保留此工具函数，`AddAccountSheet` 等仍在用）.
///
/// 真机实测（2026-09-11 18:14）登录失败原文：
/// ```
/// 错误 -2604: request failed: authentication request failed after 3 attempts
/// (HTTP 404, 503, 204): unexpected response from Apple (HTTP 204): empty or non-plist body
/// ```
/// 404/503/204 这一组是 **Apple 认证边缘的软拒绝**（请求还没进到校验凭据就返回），
/// 不是账号密码问题 —— 与苹果在 2026-09-08~10 前后收紧认证边缘的时间点吻合
/// （AltStore classic 961ea1a / c558994 两次修的就是它：503 与客户端标识）。
/// 对应处置：换网络 / 等一会儿再试 / 重置设备标识；不要连续重试（会加重限流）。
func iTunesAuthErrorMessage(_ error: Error) -> String {
    let desc = error.localizedDescription

    let softReject = ["404", "503", "204", "403"]
        .contains { desc.contains("HTTP \($0)") }
        || desc.localizedCaseInsensitiveContains("empty or non-plist body")
        || desc.localizedCaseInsensitiveContains("authentication request failed after")
    if softReject {
        return "Apple 认证边缘拒绝了这次登录（服务端软拒绝，不是账号密码错误）。\n"
             + "常见原因：短时间登录次数过多被限流、当前网络/IP 被风控。\n"
             + "建议：等 10~30 分钟或换网络（切蜂窝/Wi-Fi）再试；"
             + "也可以在「AppStore 账号管理 → 设备与认证」里重置设备标识后重试。"
    }

    if desc.contains("未能读取数据") || desc.localizedCaseInsensitiveContains("property list") {
        return "Apple 返回的认证数据格式异常（非预期 plist）。常见原因：会话/令牌过期或网络异常。"
    }
    if desc.contains("verification code") || desc.contains("认证") && desc.contains("验证码") {
        return "该账号开启了双重认证，需要验证码。请在下方输入 6 位验证码后重试。"
    }
    return "登录失败：\(desc)"
}
