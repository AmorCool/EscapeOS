import SwiftUI
import UIKit

/// Shared visual language for EscapeOS. Ported and adapted from 3105's
/// DesignSystem: a blue accent, a tinted rounded icon, and reclaim-specific
/// category styling. Uses EscapeOS's own model fields (no localization system).
enum AppTheme {
    /// Brand accent. System blue (semantic), adapts to light/dark mode.
    /// 之前是暖橙，在浅色玻璃背景下显脏棕，按用户审美改为系统蓝。
    static let accent = Color(uiColor: .systemBlue)
    static let pageInset: CGFloat = 16
    static let appIconSize: CGFloat = 44
}

/// Tinted rounded-rectangle icon used for category rows in the reclaim views.
struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = 17
    var frameSize: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

/// A card with a tinted icon, title, message, and optional action button.
/// Used for empty / error / prompt states across the app so every tab shares
/// the same visual language.
struct InfoActionCard: View {
    let icon: String
    var iconTint: Color = AppTheme.accent
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppRowIcon(systemName: icon, tint: iconTint, symbolSize: 20, frameSize: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = actionTitle, let action = action {
                    Button(action: action) {
                        Text(actionTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(AppTheme.accent)
                    .disabled(disabled)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// A small pill that highlights a byte count with a tinted background.
struct SizePill: View {
    let text: String
    var tint: Color = AppTheme.accent

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Reclaim category styling

extension ReclaimRisk {
    /// Visual role color: safe = green, session = amber, kept = grey.
    var tint: Color {
        switch self {
        case .safe: return Color.green
        case .session: return Color.orange
        case .kept: return Color.secondary
        }
    }
}

extension ReclaimCategory {
    /// SF Symbol matching each reclaim bucket, mirroring 3105's intent.
    /// The runtime `UIImage(systemName:)` guard protects against missing
    /// glyphs on older iOS builds (observed: `cookie` not rendering on some
    /// iOS 18.0 devices), falling back to a safe generic icon so the row
    /// never shows a blank tile.
    var symbol: String {
        switch id {
        case "tmp": return "clock"
        case "caches": return "internaldrive"
        case "logs": return "doc.text"
        case "splash": return "photo"
        case "gpucache": return "cpu"
        case "cookies":
            return safeSymbol(named: "cookie", fallback: "doc.text")
        case "http": return "globe"
        case "webkit": return "safari"
        case "savedstate": return "arrow.clockwise"
        case "documents": return "doc"
        case "preferences": return "gearshape"
        case "appsupport": return "folder"
        default: return "questionmark"
        }
    }

    private func safeSymbol(named primary: String, fallback: String) -> String {
        UIImage(systemName: primary) != nil ? primary : fallback
    }
}

// MARK: - Sharing

/// Identifiable wrapper for a file URL we want to share.
struct ShareTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// System share sheet (`UIActivityViewController`) for exporting a file
/// via AirDrop, Files, etc.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
