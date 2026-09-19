import Foundation

/// 一个已导入的 .tendies 壁纸包在 EscapeSpace 中的表示.
struct TendiesObject: Identifiable, Codable {
    var id = UUID()
    var name: String
    var folderName: String
    var descrNames: [String]
    var isOn: Bool = false
    var targetDescr: PBPath = .wpKit

    /// 我们**实际写进 PosterBoard 的目录名**：key = `PBPath.rawValue`，value = `applyObjects()`
    /// 当场生成的那些随机目录名。
    ///
    /// 存在的唯一目的：让「清空」有据可依。v0.3.460 的教训 —— 当时没有这份记录，只能靠
    /// 「目录内 identifier 是整数」去**猜**哪些是自定义，结果把 Apple 默认收藏也删了。
    /// 可选类型 ⇒ 旧记录解码为 `nil`（本修复之前装的壁纸没有记录，清空时一律不猜、不删）.
    var appliedDescriptors: [String: [String]]? = nil
}

/// PosterBoard 三种 descriptor 目标路径.
enum PBPath: String, Codable, CaseIterable {
    case wpKit
    case mercury
    case photos

    var path: String {
        switch self {
        case .wpKit:
            return "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"
        case .mercury:
            return "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.MercuryPoster/descriptors"
        case .photos:
            return "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.PhotosUIPrivate.PhotosPosterProvider/descriptors"
        }
    }

    var displayName: String {
        switch self {
        case .wpKit: return "Collections"
        case .mercury: return "MercuryPoster"
        case .photos: return "Videos"
        }
    }
}
