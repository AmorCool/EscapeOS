import Foundation

/// v0.3.295：AppStore 商店数据模型
/// 数据来源全部为 Apple 公开接口（iTunes Search / Lookup / 官方榜单 RSS），无需认证。
struct AppStoreItem: Identifiable, Hashable {
    var id: String                 // trackId
    var name: String               // 应用名
    var bundleId: String?
    var seller: String?            // 开发者
    var price: Double?
    var formattedPrice: String?    // 免费 / ¥xx
    var version: String?
    var fileSizeBytes: Int64?
    var rating: Double?            // 平均评分
    var ratingCount: Int?
    var primaryGenre: String?
    var genres: [String] = []
    var releaseDate: String?       // 上架时间
    var updatedDate: String?       // 当前版本更新时间
    var releaseNotes: String?      // 新功能
    var summary: String?           // 简介
    var screenshots: [String] = []
    var iconURL: String?
    var iconSmallURL: String?
    var minimumOS: String?
    var contentRating: String?
    var trackViewURL: String?
    var languages: [String] = []
    var supportedDevicesCount: Int = 0

    /// 系统 App Store 安装页（点击后由系统完成下载与安装）
    var storeURL: URL? {
        URL(string: "itms-apps://itunes.apple.com/app/id\(id)")
    }
    /// 网页版商店页（兜底）
    var webURL: URL? {
        if let trackViewURL, let u = URL(string: trackViewURL) { return u }
        return URL(string: "https://apps.apple.com/cn/app/id\(id)")
    }
    var sizeText: String? {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return nil }
        let b = Double(fileSizeBytes)
        if b >= 1024 * 1024 * 1024 { return String(format: "%.2f GB", b / 1024 / 1024 / 1024) }
        if b >= 1024 * 1024 { return String(format: "%.1f MB", b / 1024 / 1024) }
        if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
        return "\(fileSizeBytes) B"
    }
    var priceText: String {
        if let formattedPrice, !formattedPrice.isEmpty { return formattedPrice }
        if let price, price > 0 { return String(format: "¥%.2f", price) }
        return "免费"
    }
    var ratingText: String? {
        guard let rating else { return nil }
        return String(format: "%.1f", rating)
    }
}

/// 榜单类型
enum AppStoreRankKind: String, CaseIterable, Identifiable {
    case free = "topfreeapplications"
    case paid = "toppaidapplications"
    case grossing = "topgrossingapplications"
    case new = "newapplications"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return "免费榜"
        case .paid: return "付费榜"
        case .grossing: return "畅销榜"
        case .new: return "最新上架"
        }
    }
}

/// 榜单分类（App Store 中国区 genre id）
enum AppStoreGenre: String, CaseIterable, Identifiable {
    case all = "0"
    case games = "6014"
    case tools = "6002"
    case social = "6005"
    case photo = "6008"
    case entertainment = "6016"
    case shopping = "6024"
    case productivity = "6007"
    case education = "6017"
    case finance = "6015"
    case music = "6011"
    case lifestyle = "6012"
    case travel = "6003"
    case health = "6013"
    case food = "6023"
    case business = "6000"
    case news = "6009"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .games: return "游戏"
        case .tools: return "工具"
        case .social: return "社交"
        case .photo: return "摄影与录像"
        case .entertainment: return "娱乐"
        case .shopping: return "购物"
        case .productivity: return "效率"
        case .education: return "教育"
        case .finance: return "财务"
        case .music: return "音乐"
        case .lifestyle: return "生活"
        case .travel: return "旅行"
        case .health: return "健康健美"
        case .food: return "美食佳饮"
        case .business: return "商务"
        case .news: return "新闻"
        }
    }
}
