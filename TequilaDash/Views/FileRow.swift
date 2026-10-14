import SwiftUI

struct FileRow: View {
    let item: FileItem
    /// 可选的补充说明：在容器根浏览时是解析出来的 App 名.
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbolName)
                .foregroundColor(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body)
                if let subtitle {
                    // 解析名（如「全名 (bundle id)」/ group id）独立一行完整显示，
                    // 不截断省略 —— 用户需要看全.
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if !item.isDirectory {
                        Text(formatBytes(item.size))
                    }
                    if let modified = item.modified {
                        Text(Self.stamp.string(from: modified))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var kind: FileContentKind {
        FileContentKind.classify(name: item.name, isDirectory: item.isDirectory)
    }

    private var iconColor: Color {
        switch kind {
        case .directory: return .accentColor
        case .image: return .green
        case .pdf: return .red
        case .audio, .video: return .purple
        case .text, .json, .xml, .plist: return .orange
        default: return .secondary
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

