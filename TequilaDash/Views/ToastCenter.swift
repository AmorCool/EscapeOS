import SwiftUI

/// 全局 toast —— **自动消失**，避免各页面各写一份、漏清除导致「toast 一直停在屏幕上」。
///
/// 用法：任意页面写 `ToastCenter.shared.show("已安装")`，并在该页面的最外层加 `.toastHost()`。
@MainActor
final class ToastCenter: ObservableObject {

    static let shared = ToastCenter()
    private init() {}

    @Published private(set) var message: String?
    private var token = UUID()

    /// 显示一条提示；`seconds` 后自动消失（期间又弹新的则旧的失效）
    func show(_ text: String, seconds: Double = 2.2) {
        message = text
        let current = UUID()
        token = current
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.token == current else { return }
            withAnimation(.easeOut(duration: 0.18)) { self.message = nil }
        }
    }

    func clear() {
        token = UUID()
        message = nil
    }
}

/// toast 展示层
struct ToastOverlay: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let message = center.message {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.06)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 26)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: center.message)
    }
}

extension View {
    /// 挂上全局 toast 展示层（放在页面最外层）
    func toastHost() -> some View {
        overlay { ToastOverlay() }
    }
}
