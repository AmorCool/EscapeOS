import SwiftUI

/// v0.3.184：应用类型标签（应用板块列表行内）.
/// v0.3.184 7 类（细分 App Store 正版 / 共享 + 隐藏应用）.
/// v0.3.364：文案改走 `AppType.displayName`（对齐爱思；`.appStore` 兜底不再显示
/// 「AppStore」，与苹果正版同文案），并新增「越狱版」（红/粉系）.
/// 配色：蓝=正版/紫=共享/橙=企业/绿=开发/粉=越狱/灰=系统或兜底.
struct AppTypeBadge: View {
    let type: AppType
    var compact: Bool = false

    private var palette: (text: Color, fill: Color) {
        switch type {
        case .appStorePersonal: return (.blue,       .blue.opacity(0.12))
        case .appStoreShared:   return (.purple,     .purple.opacity(0.14))
        case .appStore:         return (.blue,       .blue.opacity(0.12))
        case .enterprise:       return (.orange,     .orange.opacity(0.14))
        case .development:      return (.green,      .green.opacity(0.14))
        case .jailbroken:       return (.pink,       .pink.opacity(0.16))
        case .hidden:           return (.secondary,  Color.secondary.opacity(0.10))
        case .unknown:          return (.secondary,  Color.secondary.opacity(0.10))
        }
    }

    var body: some View {
        let p = palette
        Text(type.displayName)
            .font(compact ? .caption2 : .caption.weight(.medium))
            .foregroundStyle(p.text)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                Capsule().fill(p.fill)
            )
            .accessibilityLabel("\(type.displayName)，\(type.subtitle)")
    }
}
