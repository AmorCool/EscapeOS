import Foundation

/// 一个已导入的 .tendies 壁纸包在 EscapeSpace 中的表示。
struct TendiesObject: Identifiable, Codable {
    var id = UUID()
    var name: String
    var folderName: String
    var descrNames: [String]
    var isOn: Bool = false
    var targetDescr: PBPath = .wpKit
}

/// PosterBoard 三种 descriptor 目标路径。
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
