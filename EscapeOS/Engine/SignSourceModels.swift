import Foundation

// MARK: - 软件源数据模型（唯一真源）
//
// 本文件是「软件源」模型的**唯一真源**：`SignSource` / `SignSourceApp` 只在这里定义，
// 其余文件（`SignSourceClient` / `SignSourceRSA`）**只引用不重定义**。
//
// 出处：`P3_爱思助手_逆向/EscapeSpace_软件源网络层_规格.md` §3.1 / §3.2 / §3.2.1 / §3.2.2。
// 真实抓包验证（同规格 §3.3）：顶层 8 键 + App 16 JSON 键，与静态推断逐键一致。
//
// 两条「字段缺失/类型不稳」的硬规则（**不要把正常形态当解析失败**）：
//   · 缺 `lock` ⇒ false（ESign/AltStore 家族根本没有该键，不可据此判死整个家族）；
//   · 缺 `downloadURL` ⇒ **不丢弃**该 App（`napi.ltd/pan` 这类瘦身变体改用 `suffix`），
//     仅 `isInstallable == false`（列表灰显/不可装）。

/// 顶层源对象（8 个 JSON 键）。
struct SignSource: Codable, Identifiable, Hashable {

    /// 源标识
    var identifier: String
    /// 源名
    var name: String
    /// 源地址（本地唯一键）
    var sourceURL: String
    /// 源图标（JSON 键名是**小写** `sourceicon`，见 `CodingKeys`）
    var sourceIcon: String?
    /// 源公告
    var message: String?
    /// 「获得解锁码」跳转（源级默认）
    var payURL: String?
    /// 解锁校验接口（源级默认）
    var unlockURL: String?
    /// 应用数组
    var apps: [SignSourceApp] = []

    /// 列表行标识（源地址唯一）
    var id: String { sourceURL }

    enum CodingKeys: String, CodingKey {
        case identifier, name, sourceURL, message, payURL, unlockURL, apps
        /// ⚠️ 真实键名是**小写** `sourceicon`（出处 完整性复核 §3.1-A / 抓包实证 §3.3）
        case sourceIcon = "sourceicon"
    }
}

/// 源内 App（19 属性 = 16 JSON + 3 回填/本地）。
struct SignSourceApp: Codable, Identifiable, Hashable {

    // MARK: 来自 JSON（16）

    /// 应用名
    var name: String?
    /// Bundle ID（查重/安装）
    var bundleIdentifier: String?
    /// 开发者
    var developerName: String?
    /// 版本号（**扁平单版本**，非 AltStore 的 `versions[]`）
    var version: String?
    /// 版本日期（ISO8601）
    var versionDate: String?
    /// 更新说明
    var versionDescription: String?
    /// IPA 直链（源方自托管，**非** Apple CDN）
    var downloadURL: String?
    /// 应用描述
    var localizedDescription: String?
    /// 图标
    var iconURL: String?
    /// 主题色（十六进制串）
    var tintColor: String?
    /// 字节数
    var size: UInt?
    /// 分类。⚠️ **必须用 64 位 `Int`、不可用 `UInt8`**：值形态不统一（`Int` / `"1"`），
    /// 且部分面板把 `type` 复用为**纳秒时间戳**（实测 `1788604080948514816`）⇒ 用 `UInt8` 会溢出为 nil。
    var type: Int?
    /// 1 = 需解锁码。值域实测 `{0,1,2}` ⇒ **非 0 即 true**；**缺省 false**。
    var lock: Bool = false
    /// App 级取码页；空则继承源级
    var payURL: String?
    /// App 级解锁校验；空则继承源级
    var unlockURL: String?
    /// 蓝奏云托管（值形态：整数 `0/1` 或字符串 `"0"/"1"`）
    var isLanZouCloud: Bool = false

    // MARK: 客户端回填（不入 JSON 映射；`CodingKeys` 不含它们）

    /// 所属源 URL
    var sourceURL: String?
    /// 所属源名
    var sourceName: String?

    /// 行标识（列表用）。真实源 `bundleIdentifier` 可能重复 ⇒ 用 `bundleIdentifier@version` 更稳。
    var id: String { "\(bundleIdentifier ?? name ?? "?")@\(version ?? "")" }

    /// 能否安装（列表过滤用）。缺 `downloadURL` 的 App **保留在列表**、仅 `false`（灰显/不可装）。
    var isInstallable: Bool {
        !(bundleIdentifier ?? "").isEmpty && !(downloadURL ?? "").isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, version, versionDate, versionDescription
        case downloadURL, localizedDescription, iconURL, tintColor, size, type, lock
        case payURL, unlockURL, isLanZouCloud
        // ⚠️ 刻意**不含** sourceURL / sourceName —— 它们不来自源 JSON
    }
}

// MARK: - 容错解码（§3.2.1，关键）
//
// 真实源字段类型不完全稳定（`lock` 可能是 `true` / `1` / `"1"` / `2`；`size` 可能是数字或字符串；
// `type` / `isLanZouCloud` 多数面板是字符串、少数是整数）。`Codable` 默认对类型不符会**抛错并整条失败**，
// 因此这里逐字段用 `try?` 吞掉类型不符，并显式归一化。

extension SignSourceApp {

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)
        bundleIdentifier = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? nil)
        developerName = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .developerName)) ?? nil)
        version = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil)
        versionDate = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .versionDate)) ?? nil)
        versionDescription = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .versionDescription)) ?? nil)
        downloadURL = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .downloadURL)) ?? nil)
        localizedDescription = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .localizedDescription)) ?? nil)
        iconURL = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .iconURL)) ?? nil)
        tintColor = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .tintColor)) ?? nil)
        size = Self.lossyUInt(c, .size)
        type = Self.lossyInt(c, .type)
        lock = Self.lossyBool(c, .lock) ?? false           // 缺 lock ⇒ false（不可当异常丢弃）
        payURL = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .payURL)) ?? nil)
        unlockURL = Self.nonEmpty((try? c.decodeIfPresent(String.self, forKey: .unlockURL)) ?? nil)
        isLanZouCloud = Self.lossyBool(c, .isLanZouCloud) ?? false
        // 客户端回填字段：源 JSON 里没有，保持 nil（由 `SignSource.applyInheritance()` 回填）
        sourceURL = nil
        sourceName = nil
    }

    /// 空串 → nil（§3.2.2）：真实样本里 App 级 `payURL` / `unlockURL` / `tintColor` /
    /// `localizedDescription` 都是空串 `""`，若把 `""` 当「已设置」，继承规则会失效。
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// `Bool | Int | String` → `Bool?`；**非 0 ⇒ true**（`true` / `1` / `"1"` / `"true"` / `2`）。
    private static func lossyBool(_ c: KeyedDecodingContainer<CodingKeys>,
                                  _ k: CodingKeys) -> Bool? {
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil { return v }
        if let i = (try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil { return i != 0 }
        if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "true" { return true }
            if t == "false" || t.isEmpty { return false }
            if let n = Int(t) { return n != 0 }
            return nil
        }
        return nil
    }

    /// `Int | String` → `Int?`（含大值，勿截断 —— `type` 可能是纳秒时间戳）。
    private static func lossyInt(_ c: KeyedDecodingContainer<CodingKeys>,
                                 _ k: CodingKeys) -> Int? {
        if let v = (try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil { return v }
        if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil,
           let v = Int(s.trimmingCharacters(in: .whitespaces)) { return v }
        if let d = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil { return Int(d) }
        return nil
    }

    /// `UInt | String` → `UInt?`（`size` 可能是数字或字符串 `"54489484"`）。
    private static func lossyUInt(_ c: KeyedDecodingContainer<CodingKeys>,
                                  _ k: CodingKeys) -> UInt? {
        if let v = (try? c.decodeIfPresent(UInt.self, forKey: k)) ?? nil { return v }
        if let i = (try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil, i >= 0 { return UInt(i) }
        if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil,
           let v = UInt(s.trimmingCharacters(in: .whitespaces)) { return v }
        return nil
    }
}

// MARK: - 回填与继承（§2.3 第⑤步 / §3.2.2）

extension SignSource {

    /// 把源级信息灌进每个 App：回填 `sourceURL` / `sourceName`；App 级 `payURL` / `unlockURL`
    /// 为空则继承源级（`if app.payURL == nil { app.payURL = source.payURL }`）。
    ///
    /// 依赖「空串已在解码时归一为 nil」（§3.2.2），否则 `""` 会被当成「已设置」而使继承失效。
    mutating func applyInheritance() {
        for i in apps.indices {
            apps[i].sourceURL = sourceURL
            apps[i].sourceName = name
            if apps[i].payURL == nil { apps[i].payURL = payURL }
            if apps[i].unlockURL == nil { apps[i].unlockURL = unlockURL }
        }
    }
}
