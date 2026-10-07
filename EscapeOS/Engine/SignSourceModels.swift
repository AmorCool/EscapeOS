import Foundation

// MARK: - 软件源数据模型（唯一真源）
//
// 本文件是「软件源」模型的**唯一真源**：`SignSource` / `SignSourceApp` 只在这里定义，
// 其余文件（`SignSourceClient` / `SignSourceRSA`）**只引用不重定义**。
//
// 出处：`P3_爱思助手_逆向/EscapeSpace_软件源网络层_规格.md` §3.1 / §3.2 / §3.2.1 / §3.2.2。
// 真实抓包验证（同规格 §3.3）：顶层 8 键 + App 16 JSON 键，与静态推断逐键一致。
//
// 三条「字段缺失/类型不稳」的硬规则（**不要把正常形态当解析失败**）：
//   · 缺 `lock` ⇒ false（ESign/AltStore 家族根本没有该键，不可据此判死整个家族）；
//   · 缺 `downloadURL` ⇒ **不丢弃**该 App（`napi.ltd/pan` 这类瘦身变体改用 `suffix`），
//     仅 `isInstallable == false`（列表灰显/不可装）；
//   · 缺 `bundleIdentifier` ⇒ **不影响可下载性**：它只是「apps[] 字段并集」里的一项，很多真实源
//     整源都不提供（实测 `qnq.nuosike.cn` 34/34、`hujiao.xyz` 1991/1991、`xiaoxin.kaluo.xyz`
//     28026/28026 均无该键）。`isInstallable` **只看 `downloadURL`**，绝不可绑到可选字段上
//     （否则可下载的源整源判死 ⇒ 整页灰显）。

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

    /// 行标识（列表用）。**同一源内唯一** —— 内容指纹 =
    /// `downloadURL` + `name` + `version` + `versionDate` + `size`（各字段缺失记空串，ASCII 31 分隔）。
    ///
    /// 根因（真机 `qnq.nuosike.cn`，见 `P4_全能签逆向/_impl/诊断_软件源转圈与牵扯.md` §3）：
    /// 该源**整源无 `bundleIdentifier`**（34/34），旧规则 `bundleIdentifier ?? name` `@version`
    /// 退化成 `name@version` ⇒ 前两条都是 `全能签@27.1.0` ⇒ `ForEach` 两行共享 SwiftUI 视图身份
    /// ⇒「点一条、另一条也变」（用户说的「牵扯」）。旧注释只防了「`bundleIdentifier` 重复」，
    /// 漏了「`bundleIdentifier` **缺失** ⇒ 退化成 name」这一支。
    ///
    /// 为什么取这五个字段：`downloadURL` 区分「同名不同包」（真机前两条 `downloadURL` 就不同）；
    /// `name` / `version` / `versionDate` / `size` 逐项兜住「同一 URL 被重复列出但元数据不同」的行。
    /// 语义参照全能签原版 `ais_downloadContentStampForApp:` 的 `ss|URL|name|version|versionDate|size`
    /// （`P4_全能签逆向/全能签271_列表与下载状态对照.md` §1.1），两处**刻意加强**：
    /// · 用**原始 URL** 而非 `canonicalDownloadURL`：原版做规范化是为了把「同资源、仅 fragment/大小写
    ///   不同」归到同一个**下载任务**；而 `id` 是**行身份**，目标相反 —— 任何两行都应可区分，
    ///   规范化反而会合并它们、重新制造「共享视图身份」。原始 URL 区分力更强，且与视图
    ///   `rowKey(_:)`（同为原始 `downloadURL`）一致。
    /// · 用 ASCII 31（US）而非 `|` 作分隔符：`|` 可能出现在字段内容里 ⇒ 拼接歧义；US 不会。
    ///
    /// 唯一性：只有**五个字段全部逐字相同**的两行才共享 `id`。实测（42 个源 / 50440 条，
    /// 脚本 `_verify/v6_id_size_fix_probe.py`）旧规则撞车 9315 条 ⇒ 新规则 14 条，且这 14 条
    /// **全部是 `downloadURL` 为空、其余四项逐字相同**的「源里重复列出的同一条」——它们本就
    /// 不可下载（`isInstallable == false`），共享身份无副作用、且正是「同一包同一状态」的正确语义。
    var id: String {
        let fields = [
            downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            name ?? "",
            version ?? "",
            versionDate ?? "",
            size.map { String($0) } ?? "",
        ]
        return fields.joined(separator: "\u{1F}")
    }

    /// 能否下载（列表过滤/灰显用）。**只取决于 `downloadURL` 是否可用**（非空且能构成合法 URL）。
    ///
    /// ⚠️ **刻意不看 `bundleIdentifier`**：它只是「apps[] 字段并集」里的一项，很多真实源整源都不提供
    /// （实测 `qnq.nuosike.cn` 34/34、`hujiao.xyz` 1991/1991、`xiaoxin.kaluo.xyz` 28026/28026 均无该键，
    /// 而 `pgyy.github.io` 却有 —— 见 `P4_全能签逆向/第三方源生态普查.md`）。把「能否下载」绑到一个
    /// **可选**字段上，会把可下载的源整源判死（恒 `false` ⇒ 每行灰显 + 「获取」恒禁用）。`bundleIdentifier`
    /// 只用于「去重/识别同一 App」这类次要能力，缺失**不应**影响可下载性。
    ///
    /// 缺 `downloadURL` 的 App **保留在列表**、仅 `false`（灰显/不可装），不丢弃。
    var isInstallable: Bool {
        guard let s = downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return false
        }
        return URL(string: s) != nil
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
    ///
    /// 排查结论（同批 `lossy*` 审查）：`lock` / `isLanZouCloud` 的实测值域只有 `bool` / `int` /
    /// `string` 三种载体（`lock ∈ {0,1,2}`、`isLanZouCloud ∈ {0,1}`），**无小数形态** ⇒ 无需补分支。
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

    /// `Int | Double | String` → `Int?`（含大值，勿截断 —— `type` 可能是纳秒时间戳）。
    ///
    /// 排查（与 `lossyUInt` 同类的形态问题）：旧实现认 `Int` / **整数**串 / JSON 小数（`Double`），
    /// 但**漏了小数串**（`Int("1.5")` 失败且无 `Double` 回退）；且旧的 `Int(d)` 在 `d` 为
    /// `NaN` / `±∞` / 越界时会 **trap**（`type` 来自不可信源 JSON）⇒ 一并补上。
    private static func lossyInt(_ c: KeyedDecodingContainer<CodingKeys>,
                                 _ k: CodingKeys) -> Int? {
        if let v = (try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil { return v }
        if let d = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil { return intFromDouble(d) }
        if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let v = Int(t) { return v }
            if let d = Double(t) { return intFromDouble(d) }
        }
        return nil
    }

    /// `UInt | Int | Double | String` → `UInt?`（`size` = 字节数）。
    ///
    /// 真实形态（实测 50440 条 `size`，见 `P4_全能签逆向/_impl/修复_应用大小丢失.md` §①）：
    /// 整数字符串 60.1% / **小数字符串 38.2%** / JSON 数字 1.3% / 空串 0.4% / 脏值 4 条。
    /// 旧实现只认 `UInt` / `Int≥0` / **整数**串，**漏了占 38.2% 的小数串**（如截图那条
    /// `"9384755.2"` = 8.95 MB）⇒ `size = nil` ⇒ 视图不显示大小胶囊。此修复补上 `Double` 分支。
    ///
    /// 语义对齐全能签原版 `ais_formatBytes:`：`size` 字符串 → `double`（小数截断）；`≤ 0` 视为无效
    /// （模型返回 `0`，由视图 `s > 0` 决定不显示 —— 原版显示 `—` 属视图口径，本次只改模型）。
    /// lossy 语义不变：缺字段 / 空串 / 非数值 / 负值 / `NaN` / `±∞` / 越界 → `nil`（**不崩**）。
    private static func lossyUInt(_ c: KeyedDecodingContainer<CodingKeys>,
                                  _ k: CodingKeys) -> UInt? {
        if let v = (try? c.decodeIfPresent(UInt.self, forKey: k)) ?? nil { return v }
        if let i = (try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil, i >= 0 { return UInt(i) }
        if let d = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil { return uintFromDouble(d) }
        if let s = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let v = UInt(t) { return v }
            if let d = Double(t) { return uintFromDouble(d) }
        }
        return nil
    }

    /// `Double` → `UInt`，**截断小数**；`NaN` / `±∞` / 负值 / 越界 → `nil`
    /// （`size` 来自不可信源 JSON，绝不让 `UInt(_:)` 因 `inf` / 越界 trap）。
    private static func uintFromDouble(_ d: Double) -> UInt? {
        guard d.isFinite, d >= 0, d < 18_446_744_073_709_551_616.0 else { return nil }   // 2^64
        return UInt(d)
    }

    /// `Double` → `Int`，**截断小数**；`NaN` / `±∞` / 越界 → `nil`（同上，防 `Int(_:)` trap）。
    private static func intFromDouble(_ d: Double) -> Int? {
        guard d.isFinite, d >= -9_223_372_036_854_775_808.0,
              d < 9_223_372_036_854_775_808.0 else { return nil }                        // [-2^63, 2^63)
        return Int(d)
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
