import SwiftUI

/// v0.3.181：应用类型标签（应用板块列表行内）。
/// 不同类型用不同淡颜色小胶囊显示（AppStore=蓝、企业=橙、AdHoc=紫、Dev=绿、未知=灰）。
struct AppTypeBadge: View {
    let type: AppType
    var compact: Bool = false

    private var palette: (text: Color, fill: Color) {
        switch type {
        case .appStore:    return (.blue,    .blue.opacity(0.12))
        case .enterprise:  return (.orange,  .orange.opacity(0.14))
        case .adHoc:       return (.purple,  .purple.opacity(0.14))
        case .development: return (.green,   .green.opacity(0.14))
        case .unknown:     return (.secondary, Color.secondary.opacity(0.10))
        }
    }

    var body: some View {
        let p = palette
        Text(type.rawValue)
            .font(compact ? .caption2 : .caption.weight(.medium))
            .foregroundStyle(p.text)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                Capsule().fill(p.fill)
            )
            .accessibilityLabel("\(type.rawValue)，\(type.subtitle)")
    }
}