import Foundation

/// v0.3.315：**从「免登录源」（爱思 PC 端公开接口）按 bundleId 定位可安装的 IPA**。
///
/// 用途：
/// · 设备瘦身「较大应用」重装时本地没有包 → 现场按 bundleId 去源里找；
/// · AppStore 商店详情页「获取」时优先走免登录源直装。
///
/// 查找方式：用应用名（必要时退化成 bundleId 字面量）走搜索接口，再按 **bundleId 精确匹配**
/// ——搜索结果是模糊匹配，必须自己核对 bundleId，否则会装错应用。
enum SourcePackageLocator {

    struct Hit {
        let ipaURL: String
        let bundleId: String
        let name: String
        let version: String?
    }

    /// - Parameters:
    ///   - bundleId: 目标应用 bundle id（必填，用于精确匹配）
    ///   - name: 应用显示名（搜索关键词）
    static func find(bundleId: String, name: String) async -> Hit? {
        let target = bundleId.lowercased()
        guard !target.isEmpty else { return nil }
        var keywords: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { keywords.append(trimmed) }
        keywords.append(bundleId)

        for keyword in keywords {
            let list = (try? await I4PCStoreClient.search(keyword: keyword, rows: 20)) ?? []
            for app in list {
                guard (app.bundleId ?? "").lowercased() == target, let url = app.ipaURL else { continue }
                return Hit(ipaURL: url.absoluteString,
                           bundleId: app.bundleId ?? bundleId,
                           name: app.name,
                           version: app.version)
            }
        }
        return nil
    }
}
