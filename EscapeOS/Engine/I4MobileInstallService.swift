import Foundation

/// 爱思「安装移动端」服务层（只做逻辑，不含 UI）—— 移植自爱思助手 PC 端 9.0.
///
/// ## IPA 从哪来（v5：仓库云端 + 自定义包体 + 手动导入）
/// 本服务**不读 app bundle 里的内嵌 IPA**，来源共**三条**（用户指定），都落盘到同一个缓存目录
/// `Caches/I4MobileIPA/`：
///   ① **仓库云端** —— `downloadCloudIPA(pack:from:.warehouse)` 按 `pack.cloudURL` 下到缓存目录；
///   ② **自定义包体** —— 用户填一个 IPA 直链（`addCustomPack(urlString:)`）加入列表后，走 ① 同一条下载链路；
///   ③ **手动导入** —— `importIPA(from:)` 把用户选中的 IPA 拷进缓存目录.
/// 安装时**只认缓存目录**（`resolveURL`）；缓存缺失即 `packResourceMissing`，
/// **不做隐式下载、不兜底到 bundle** —— 用户明确要求去掉「内置进 app bundle」.
///
/// `pack.cloudURL` = 该包的下载直链：内置三包指向模块仓库 `AmorCool/module-esc` 的 `edge` Release
/// （见 `P3_爱思助手_逆向/_简报/实现_模块仓库托管IPA.md` ④，下载后 md5 已核）；自定义包体 = 用户自填地址.
///
/// > 历史：v4 曾有第二条云端「爱思云端」（`app4.i4.cn/getipaformobiledevice.xhtml`）。
/// > 该接口经 Python 直连实测恒回 `{"code":1,"msg":"exception"}`，穷举 key / 算法 / 填充 /
/// > 编码 / 参数 / UA / 域名 / pcver **全矩阵 0 命中** ⇒ **后端侧问题，App 侧无法修**，
/// > 用户决定删除。相关实现（`I4CloudResolver` / `I4CloudResolverImpl` / `UnavailableI4CloudResolver`）
/// > 已整块移除，见 `P4_全能签逆向/_简报/实现_删爱思云端与仓库云端自选包体.md`.
///
/// ## 移植的是什么（v2：修正 sinf 来源）
/// 爱思 PC 端「安装爱思移动端」的真实做法**不是**「把包内自带的 sinf 直接递给 installd」：
///   ① 解压内嵌 IPA（libzip）；
///   ② 往包里**写一份 sinf**（覆盖 `Payload/<X>.app/SC_Info/<exe>.sinf`）——
///      这份 sinf 来自 **Apple 服务端**（`MZFinance` 响应 `songList[].sinfs[0]`），
///      **不是**包内原有的那份；
///   ③ 重打包；
///   ④ `idm_app.dll` 再从包里**读回**这份 sinf，作为 `ApplicationSINF` 参数交 installd。
/// 核心函数 `addSinfToZip()`（VA `0x1407dd6b0`），目标路径模板 `Payload/%1/SC_Info/%2.sinf`；
/// 重取路径 `WriteAppSignature start` → 轮询 → 下载解析 → `addSinfToZip`.
///
/// ## 自动选包（v6：移植爱思「按 iOS 版本瀑布降级选一个包」）
/// 爱思选包不是随机挑，而是按设备 iOS 版本瀑布降级（函数 `0x1401db840`，见
/// `P3_爱思助手_逆向/_简报/逆向_爱思自动选包机制.md`）：⓪ 已装 `com.ownbook.notes` 短路 →
/// ① iOS ≥ 15.1 且 `v9items["305"].policy ≠ 0` → 305 → ② iOS ≥ 13.0 → 220 →
/// ③ iOS ≥ 10.0 → 217 → ④ iOS ≥ 9.0 且机型 `iPhone4,1` → 213 → ⑤ 兜底 → 723.
/// 本仓内置只有 `220` / `217` / `photo`（`photo` 不在瀑布内）；`305` / `213` / `723` **无包体**
/// ⇒ 命中时如实回落（同爱思 `policy==0` 的行为），见 `autoPick(profile:)`.
///
/// ## 为什么必须现取 sinf（决定性证据）
/// 三个爱思移动端 IPA 包内自带的 sinf，其 `schi.name` 属**原始购买者**，**不是**爱思共享账号
/// `share_appleid003@163.com`（三包 `iTunesMetadata.appleId` 才是该共享账号）：
///   · `217.ipa`   `schi.user=0xab6d95d8` `schi.name=李 明`
///   · `220.ipa`   `schi.user=0xa775eea7` `schi.name=小 敏`
///   · `photo.ipa` `schi.user=0xab5c9f49` `schi.name=chongwei stven`
/// ⇒ 包内 sinf 与「本设备」无关，直接递交 installd **必然**过不了 FairPlay（装不上，
/// 或装上后运行期 `fairplayOpen()` 失败而闪退，即 `-42112` 一类）。
/// 这正是本服务 v1 的错误：它 `extractSINF` 取包内自带、直接装。
///
/// ## sinf 来源（只有一条路，照爱思）
/// **NB 服务端** —— `NBStoreClient.packageByVersion(appID:appVerId:bundleID:country:)`
/// 按「包内 `iTunesMetadata` 的 `itemId` + `softwareVersionExternalIdentifier`」
/// 现取该版本的 sinf，**写进包内覆盖**，再装。
/// 取不到即**明确失败**（抛 `serverSinfUnavailable`），**不回退到包内自带**。
///
/// **为什么不做「优先级 + 兜底」**：包内自带 sinf 属**原始购买者**（实测 `schi.name`
/// = 李 明 / 小 敏 / chongwei stven），把它当兜底会让「装上了但闪退」变成常态，
/// 而不是**明确报错** —— 那比不做更糟。故只有服务端这一条路。
///
/// ## 实现（照爱思）
/// 复制 IPA 到临时目录（**绝不改缓存原件**）→ `PackageSINFWriter.injectAllPaths`
/// 把 sinf 写进副本的 `SC_Info/*.sinf` → `IPAInstallService.installWithSINF` 装那份副本
/// （同一份 sinf 同时作为 `ApplicationSINF` 递交，与爱思「写进包再读回」等价）。
///
/// ## 诚实边界（写进返回值，不只在注释里）
/// - `Report.sinfSource` 恒为 `"server"`（本服务只有服务端这一条路）；
///   `Report.sinfAccountName` / `sinfAccountUser` 由 `schi` 解析得出
///   （让用户看到「这是谁的授权」）。
/// - `Report.launchVerified` **恒为 `false`**（本服务只做安装，不验证能否启动）。
/// - 日志走 `onLog` 闭包（不直接写 `LoginLogger`）；调用方可转发到
///   `LoginLogger.shared.log(_:category: .i4Fix)`。
///
/// ## 为什么是 `enum` + `static`（而非单例）
/// 底层 `IPAInstallService.shared`（`@unchecked Sendable`）与 `AppDiscovery` 各自管着 RSD
/// 串行队列；本服务自身**没有任何可变状态**，用 `static` 方法即可，避免引入需要
/// `nonisolated(unsafe)` 的非 Sendable 单例（Swift 6 严格并发）。调用方负责把阻塞调用放到后台线程.
enum I4MobileInstallService {

    // MARK: - 常量

    /// IPA 缓存目录名（`Caches/I4MobileIPA/`）：云端下载与手动导入的 IPA 都落在这里.
    ///
    /// 为什么用 `Caches` 而不是 `Documents`：这些 IPA 是可再下载的派生物、不属于用户数据，
    /// 放 Caches 符合 Apple 存储指引，系统在空间紧张时可回收（回收后重新下载 / 重新导入即可）.
    static let cacheDirectoryName = "I4MobileIPA"

    /// 自定义包体的持久化键（UserDefaults，存 `CustomPackRecord` 的 JSON 数组）.
    private static let customPacksKey = "I4Mobile.customPacks"

    /// 爱思共享 Apple ID（三包 `iTunesMetadata` 的 `appleId`，见 `爱思9_安装移动端.md` §②）.
    static let sharedAccountEmail = "share_appleid003@163.com"

    /// 3 个「爱思移动端」IPA 的元数据（`fileName` 同时是缓存目录里的落盘名）.
    ///
    /// `expectedBundleId` / `expectedVersion` 用于**安装前后探测设备上的同名 App**，
    /// 以及**手动导入时按包内 bundle id 认领**；实际安装用的 bundle id 仍以**包内 Info.plist** 为准.
    ///
    /// `cloudURL` = 该包的**仓库云端**下载直链（模块仓库 `AmorCool/module-esc` 的 `edge` Release），
    /// 三个包均已填好（md5 已核，见 `实现_模块仓库托管IPA.md` ④）.
    static let packs: [Pack] = [
        Pack(fileName: "217.ipa",   expectedBundleId: "rn.notes.best",      expectedVersion: "2.1.7",
             cloudURL: "https://github.com/AmorCool/module-esc/releases/download/edge/217.ipa"),
        Pack(fileName: "220.ipa",   expectedBundleId: "com.ownbook.notes",  expectedVersion: "2.2.0",
             cloudURL: "https://github.com/AmorCool/module-esc/releases/download/edge/220.ipa"),
        Pack(fileName: "photo.ipa", expectedBundleId: "com.MK.AwsomeFiles", expectedVersion: "1.5",
             cloudURL: "https://github.com/AmorCool/module-esc/releases/download/edge/photo.ipa"),
    ]

    // MARK: - 模型

    /// 一个「爱思移动端」IPA（`fileName` 同时是缓存目录里的落盘名）.
    struct Pack: Identifiable, Hashable, Sendable {
        /// 缓存目录内的文件名（如 `217.ipa`）.
        let fileName: String
        /// 期望的 bundle id（探测设备同名 App / 手动导入认领用；实际以包内 Info.plist 为准）.
        /// 自定义包体在加入时未知，留空串（安装时以包内 Info.plist 为准）.
        let expectedBundleId: String
        /// 期望版本（仅供参考，实际以包内 Info.plist 为准）.
        let expectedVersion: String
        /// 下载直链（内置包 = 模块仓库 `edge` Release；自定义包体 = 用户自填地址）. 空串 = 未配置.
        let cloudURL: String
        /// 是否为用户自定义包体（内置三包为 `false`）.
        var isCustom: Bool = false
        var id: String { fileName }
    }

    /// `schi` 块解析结果（sinf 里描述「这份授权属于谁」）.
    struct SinfAccount: Sendable, Equatable {
        /// `schi.name`：账号显示名（如 `李 明`）.
        let name: String?
        /// `schi.user`：账号标识（4 字节，十六进制，如 `0xab6d95d8`）.
        let userHex: String?
        /// `schi.crdt`：凭据标识（4 字节，十六进制）.
        let crdtHex: String?
    }

    /// sinf 解析结果（内部用，不跨 `Report` 边界）.
    struct SinfResolution: Sendable {
        let sinf: Data
        let account: SinfAccount?
    }

    /// 云端下载来源.
    ///
    /// 只有 `.warehouse` 一条：仓库云端 —— 本模块仓库 `AmorCool/module-esc` 的 `edge` Release 直链
    /// （内置包 `pack.cloudURL`；自定义包体为用户自填地址）.
    ///
    /// > 历史：v4 曾有 `.i4`「爱思云端」（需设备 UDID、由服务端按包解析地址）。该接口后端实测不可用，
    /// > 用户决定删除，`.i4` 随之移除.
    enum CloudSource: String, Sendable {
        case warehouse

        /// 展示名（界面用；中文，标点用英文句点）.
        var displayName: String {
            switch self {
            case .warehouse: return "仓库云端"
            }
        }
    }

    /// 某来源对某个包的可用性（供 UI **如实显示**，不静默跳过）.
    enum CloudAvailability: Sendable, Equatable {
        /// 可用（`detail` 为展示用说明，如直链；可为空）.
        case available(detail: String?)
        /// 不可用 + **原因**（UI 必须把原因显示出来）.
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        /// 不可用原因（可用时为 `nil`）.
        var unavailableReason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// 一个包的**缓存就位情况 + 仓库云端可用性**（供 UI 展示；只查本地文件，不读设备）.
    struct PackStatus: Identifiable, Sendable {
        let pack: Pack
        /// 缓存目录里是否已有该 IPA（且非空）.
        let cached: Bool
        /// 已缓存 IPA 的字节数（未缓存为 0）.
        let bytes: Int
        /// **仓库云端**可用性（`cloudURL` 非空且可解析为 URL 即可用）.
        let warehouseAvailability: CloudAvailability
        var id: String { pack.fileName }
    }

    /// 设备侧探测快照（安装前/后各取一次；探测失败**不抛错**，如实记 `error`）.
    struct DeviceProbe: Sendable {
        /// 设备上已存在的**同名 bundle id** App 的版本（未安装则 `nil`）.
        let existingVersion: String?
        /// 探测失败原因（`nil` = 探测成功）.
        let error: String?
    }

    /// 一次安装的**如实结果**（不美化）.
    ///
    /// 诚实边界在这里显式暴露：`sinfSource`（恒为 `"server"`）/ `sinfAccountName`
    /// 让用户看到「用的是谁的授权」；`launchVerified` 恒为 `false`.
    struct Report: Sendable {
        let pack: Pack
        /// 原始资源 IPA 路径与大小.
        let ipaPath: String
        let ipaBytes: Int
        /// **实际安装的那份**临时副本路径（注入了 sinf；不改原件）.
        let workIPAPath: String
        /// sinf 来源：固定 `"server"`（本服务只有服务端这一条路）.
        let sinfSource: String
        /// sinf 的 `schi` 账号名 / user（解析出来展示；解析失败为 `nil`）.
        let sinfAccountName: String?
        let sinfAccountUser: String?
        /// 递交 installd 的 `sinf` 字节数.
        let sinfBytes: Int
        /// 实际写入包内的 sinf 路径（相对 IPA 根）.
        let injectedPaths: [String]
        /// 是否随包递交了 `iTunesMetadata`.
        let hasITunesMetadata: Bool
        /// 是否用 `Upgrade` 命令（覆盖安装）.
        let upgrade: Bool
        /// 包内 Info.plist 读到的 bundle id / 版本（读不出则回退期望值）.
        let bundleId: String
        let bundleVersion: String
        /// 安装前 / 后设备探测.
        let before: DeviceProbe
        let after: DeviceProbe
        /// 安装后设备上是否出现该 bundle id（回读确认；探测失败时为 `nil`）.
        let installedConfirmed: Bool?
        /// **恒为 `false`**：本服务不验证包能否在本机启动.
        let launchVerified: Bool
        /// 启动风险提示：安装后未在设备上回读到时为 `true`.
        let mayCrashAtLaunch: Bool
        /// 如实的补充说明（逐条事实 + 边界）.
        let notes: [String]
        /// 一句话结论（含边界）.
        let verdict: String
    }

    // MARK: - 错误

    enum I4MobileError: LocalizedError {
        /// 缓存里没有该 IPA（既未下载也未导入）.
        case packResourceMissing(String)
        /// 某云端来源对该包不可用（未配置地址 / 契约未定）；`reason` 如实说明.
        case cloudSourceUnavailable(pack: String, source: String, reason: String)
        /// 写缓存失败（下载落盘 / 导入拷贝 / 删除旧文件）.
        case cacheWriteFailed(String)
        /// 导入的 IPA 认不出属于哪个包（包内 bundle id 读不出，或不属于这组）.
        case importUnrecognized(String)
        /// 服务端取 sinf 失败（缺 store id / 服务端没回 sinf / 结构不合法）.
        case serverSinfUnavailable(reason: String)
        /// 复制工作副本失败（临时目录 / 复制 IPA）.
        case workCopyFailed(String)
        /// 把 sinf 写进副本失败.
        case sinfInjectFailed(String)
        /// 自定义包体的 URL 不合法（空 / 非 http(s) / 无主机名）.
        case customPackInvalid(reason: String)

        var errorDescription: String? {
            switch self {
            case .packResourceMissing(let name):
                return "缓存里没有 \(name)：请先在云端下载，或手动导入该 IPA."
            case .cloudSourceUnavailable(let pack, let source, let reason):
                return "\(source) 对 \(pack) 不可用：\(reason)"
            case .cacheWriteFailed(let reason):
                return "写入 IPA 缓存失败：\(reason)"
            case .importUnrecognized(let reason):
                return "导入的 IPA 不属于爱思移动端这组：\(reason)"
            case .serverSinfUnavailable(let reason):
                return "服务端未取到可用的 sinf：\(reason)"
            case .workCopyFailed(let reason):
                return "准备工作副本失败：\(reason)"
            case .sinfInjectFailed(let reason):
                return "把 sinf 写进安装包副本失败：\(reason)"
            case .customPackInvalid(let reason):
                return "自定义包体地址不可用：\(reason)"
            }
        }
    }

    // MARK: - ① 缓存目录 / 来源（云端下载 · 手动导入）/ 定位

    /// IPA 缓存目录 `Caches/I4MobileIPA/`（云端下载与手动导入的共同落盘处）.
    ///
    /// 只算路径，不建目录（`isCached` 等只读查询不该有副作用）；需要写入时由
    /// `downloadCloudIPA` / `importIPA` 显式创建.
    static func cacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    /// 某个包在缓存目录里的落盘位置（`Caches/I4MobileIPA/<fileName>`）.
    static func cachedIPAURL(for pack: Pack) -> URL {
        cacheDirectory().appendingPathComponent(pack.fileName)
    }

    /// 该包的 IPA 是否已缓存（文件存在且非空）.
    static func isCached(_ pack: Pack) -> Bool {
        fileSize(at: cachedIPAURL(for: pack).path) > 0
    }

    /// 定位包资源：**只在缓存目录里找**（云端下载与手动导入都写这里）.
    /// 没有则返回 `nil`（调用方抛 `packResourceMissing`）.
    static func resolveURL(for pack: Pack) -> URL? {
        let url = cachedIPAURL(for: pack)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 删除某个包的缓存 IPA（清理用）.
    static func removeCachedIPA(_ pack: Pack) throws {
        let url = cachedIPAURL(for: pack)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw I4MobileError.cacheWriteFailed(error.localizedDescription)
        }
    }

    /// 列出各包（内置 + 自定义）缓存是否就位 + 仓库云端可用性（供 UI 展示）.
    static func packStatuses() -> [PackStatus] {
        allPacks.map { pack in
            let bytes = fileSize(at: cachedIPAURL(for: pack).path)
            let warehouse: CloudAvailability =
                (!pack.cloudURL.isEmpty && URL(string: pack.cloudURL) != nil)
                ? .available(detail: pack.cloudURL)
                : .unavailable(reason: "未配置下载直链.")
            return PackStatus(pack: pack, cached: bytes > 0, bytes: bytes,
                              warehouseAvailability: warehouse)
        }
    }

    // MARK: - 自定义包体（用户自填 IPA 直链）

    /// 用户自定义包体的持久化记录（UserDefaults 里存 JSON 数组）.
    private struct CustomPackRecord: Codable {
        let fileName: String
        let url: String
    }

    /// 读用户自定义包体（按加入顺序）；无记录 / 记录损坏时返回空数组.
    static func customPacks() -> [Pack] {
        readCustomPackRecords().compactMap { record in
            guard !record.fileName.isEmpty, !record.url.isEmpty,
                  let url = URL(string: record.url) else { return nil }
            return Pack(fileName: record.fileName, expectedBundleId: "", expectedVersion: "",
                        cloudURL: url.absoluteString, isCustom: true)
        }
    }

    /// 内置三包 + 用户自定义包体（顺序：内置在前，自定义按加入顺序在后）.
    static var allPacks: [Pack] { packs + customPacks() }

    /// 加入一个自定义包体（用户填的 IPA 直链），持久化后返回该 `Pack`.
    ///
    /// 校验（不合法即抛 `customPackInvalid`，**不假装可用**）：
    ///   · 去空白后非空；
    ///   · 可解析为 URL 且 scheme 为 `http` / `https`、主机名非空.
    /// 落盘名由 URL 末段推导（非 `.ipa` 结尾则补 `.ipa`），与内置包 / 已有自定义包重名时自动加序号.
    /// 同一 URL 重复加入 ⇒ 返回已存在的那条（幂等）.
    @discardableResult
    static func addCustomPack(urlString: String) throws -> Pack {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw I4MobileError.customPackInvalid(reason: "地址为空.")
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw I4MobileError.customPackInvalid(reason: "不是合法的 http / https 直链.")
        }
        let normalized = url.absoluteString
        var records = readCustomPackRecords()
        if let same = records.first(where: { $0.url == normalized }) {
            return Pack(fileName: same.fileName, expectedBundleId: "", expectedVersion: "",
                        cloudURL: normalized, isCustom: true)
        }
        let taken = Set(packs.map(\.fileName) + records.map(\.fileName))
        let fileName = uniqueFileName(base: customFileName(for: url), taken: taken)
        records.append(CustomPackRecord(fileName: fileName, url: normalized))
        writeCustomPackRecords(records)
        return Pack(fileName: fileName, expectedBundleId: "", expectedVersion: "",
                    cloudURL: normalized, isCustom: true)
    }

    /// 移除一个自定义包体（含其缓存文件）；内置包不可移除（静默忽略）.
    static func removeCustomPack(_ pack: Pack) throws {
        guard pack.isCustom else { return }
        var records = readCustomPackRecords()
        let before = records.count
        records.removeAll { $0.fileName == pack.fileName }
        if records.count != before {
            writeCustomPackRecords(records)
        }
        try removeCachedIPA(pack)
    }

    /// 校验缓存里的包体确为可识别的 IPA（读包内 bundle id）；读不出即抛 `customPackInvalid`.
    ///
    /// 用于自定义包体下载后确认「下到的确实是 IPA」——**下载完就校验，不合规就报错并删除残包**.
    static func verifyCachedIPA(_ pack: Pack) throws -> (bundleId: String, version: String) {
        guard let url = resolveURL(for: pack) else {
            throw I4MobileError.packResourceMissing(pack.fileName)
        }
        guard let inspection = IPAPackageInspector.inspect(ipaPath: url.path),
              let bundleId = inspection.bundleIdentifier, !bundleId.isEmpty else {
            throw I4MobileError.customPackInvalid(reason: "下载到的文件不是可识别的 IPA（读不出包内 bundle id）.")
        }
        return (bundleId, inspection.bundleVersion ?? "")
    }

    /// 由 URL 末段推导缓存落盘名（非 `.ipa` 结尾则补 `.ipa`）.
    private static func customFileName(for url: URL) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let base = last.isEmpty ? "custom.ipa" : last.replacingOccurrences(of: "/", with: "_")
        return base.lowercased().hasSuffix(".ipa") ? base : base + ".ipa"
    }

    /// 在已被占用的文件名集合里生成一个不冲突的名字（冲突则加 `-2` / `-3` …）.
    private static func uniqueFileName(base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        let stem = base.lowercased().hasSuffix(".ipa") ? String(base.dropLast(4)) : base
        var i = 2
        while taken.contains("\(stem)-\(i).ipa") { i += 1 }
        return "\(stem)-\(i).ipa"
    }

    private static func readCustomPackRecords() -> [CustomPackRecord] {
        guard let data = UserDefaults.standard.data(forKey: customPacksKey),
              let records = try? JSONDecoder().decode([CustomPackRecord].self, from: data) else {
            return []
        }
        return records
    }

    private static func writeCustomPackRecords(_ records: [CustomPackRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: customPacksKey)
    }

    // MARK: - ⑤ 页面展示辅助（下载地址摘要）

    /// 某来源的**下载地址摘要**（供页面**只读展示**，不参与下载 —— 真正的下载地址由
    /// `cloudURL(for:source:)` 现解析）.
    ///
    /// · `.warehouse`：内置包的仓库 Release 直链同处一个目录，返回该目录（前缀）；
    ///   某个包的实际地址 = 前缀 + `pack.fileName`（如 `…/edge/217.ipa`）.
    ///
    /// 为什么只读、不做成可编辑：内置包地址是编译期常量（`Pack.cloudURL`）；
    /// 自定义包体的地址在「自定义包体」入口单独填（加入后即被 `downloadCloudIPA` 消费，非假配置）.
    static func addressSummary(for source: CloudSource) -> String? {
        switch source {
        case .warehouse:
            guard let first = packs.first, !first.cloudURL.isEmpty else { return nil }
            guard let slash = first.cloudURL.lastIndex(of: "/") else { return first.cloudURL }
            return String(first.cloudURL[...slash])
        }
    }

    // MARK: - ② IPA 来源 · 云端下载（仓库云端）

    /// 按来源解析某包的下载地址（仓库云端取 `pack.cloudURL`）.
    ///
    /// 不可用一律抛 `cloudSourceUnavailable`（含来源名与原因，**不静默跳过**）.
    static func cloudURL(for pack: Pack, source: CloudSource) async throws -> URL {
        switch source {
        case .warehouse:
            guard !pack.cloudURL.isEmpty, let url = URL(string: pack.cloudURL) else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.warehouse.displayName,
                    reason: "未配置下载直链.")
            }
            return url
        }
    }

    /// 从**指定云端来源**下载某个包的 IPA 到缓存目录（**已缓存则跳过**，避免重复下载 60+ MB）.
    ///
    /// 传输复用 `AppStoreInstallService.downloadIPA`（`URLSessionDownloadTask`，
    /// 自带重定向 / UA / 超时 / 断点续传），它落盘到 `Documents/AppStoreDownloads/`；
    /// 本服务再把结果**移入**缓存目录 `Caches/I4MobileIPA/`（同一容器内，重命名即可）——
    /// 既复用成熟下载器，又把可回收的 IPA 放在 Caches.
    ///
    /// - Parameters:
    ///   - source: 下载来源（`.warehouse` 仓库云端）.
    /// - Throws: `cloudSourceUnavailable`（来源不可用）/ `cacheWriteFailed`（落盘失败）/ 底层下载错误.
    static func downloadCloudIPA(pack: Pack,
                                 from source: CloudSource = .warehouse,
                                 progress: (@Sendable (Double) -> Void)? = nil,
                                 onLog: (@Sendable (String) -> Void)? = nil) async throws {
        if isCached(pack) {
            onLog?("[i4移动端] \(pack.fileName) 已在缓存，跳过下载")
            return
        }
        let url = try await cloudURL(for: pack, source: source)
        onLog?("[i4移动端] \(source.displayName) 下载 \(pack.fileName)：\(url.absoluteString)")
        let downloaded = try await AppStoreInstallService.downloadIPA(
            urlString: url.absoluteString,
            suggestedName: pack.fileName,
            progress: progress,
            onLog: onLog)
        let dst = cachedIPAURL(for: pack)
        do {
            try FileManager.default.createDirectory(at: cacheDirectory(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.moveItem(at: downloaded, to: dst)
        } catch {
            throw I4MobileError.cacheWriteFailed(error.localizedDescription)
        }
        onLog?("[i4移动端] 已缓存 \(pack.fileName) · \(fileSize(at: dst.path) / 1024 / 1024) MB")
    }

    /// 从指定来源下载所有**未缓存**的包（顺序 = `allPacks`：内置在前，自定义在后）.
    ///
    /// 诚实边界：任一包失败即抛错，**不回滚**已下载的包（与 `installAll` 一致）.
    /// 调用方（UI）应先用 `packStatuses()` 过滤出**可用**的包，避免对不可用包空转报错.
    static func downloadAllMissingCloudIPAs(from source: CloudSource = .warehouse,
                                            progress: (@Sendable (Double) -> Void)? = nil,
                                            onLog: (@Sendable (String) -> Void)? = nil) async throws {
        let missing = allPacks.filter { !isCached($0) }
        for (idx, pack) in missing.enumerated() {
            onLog?("[i4移动端] (\(idx + 1)/\(missing.count)) 下载 \(pack.fileName)")
            try await downloadCloudIPA(pack: pack, from: source,
                                       progress: progress, onLog: onLog)
        }
    }

    // MARK: - ③ IPA 来源 · 手动导入

    /// 把用户手动选中的 IPA 拷进缓存目录.
    ///
    /// 认领规则：读包内 `CFBundleIdentifier`，在 `packs` 里按 `expectedBundleId` 匹配；
    /// 读不出或匹配不到即抛 `importUnrecognized`（**不猜、不按文件名硬套**）.
    /// 落盘名 = 匹配到的 `pack.fileName`，因此导入后 `resolveURL` / `install` 直接可用.
    ///
    /// - Parameter sourceURL: 已在本 App 沙盒内的可读 URL（`SharedDocumentPicker` 的 `asCopy`
    ///   已把用户选中的文件拷进沙盒，无需 security-scoped 访问）.
    /// - Returns: 认领到的 `Pack`.
    static func importIPA(from sourceURL: URL,
                          onLog: (@Sendable (String) -> Void)? = nil) throws -> Pack {
        let inspection = IPAPackageInspector.inspect(ipaPath: sourceURL.path)
        guard let bundleId = inspection?.bundleIdentifier, !bundleId.isEmpty else {
            throw I4MobileError.importUnrecognized("读不出包内 bundle id（文件可能不是有效 IPA）")
        }
        guard let pack = packs.first(where: { $0.expectedBundleId == bundleId }) else {
            let known = packs.map(\.expectedBundleId).joined(separator: ", ")
            throw I4MobileError.importUnrecognized("包内 bundle id=\(bundleId) 不在爱思移动端这组（\(known)）")
        }
        let dst = cachedIPAURL(for: pack)
        do {
            try FileManager.default.createDirectory(at: cacheDirectory(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dst)
        } catch {
            throw I4MobileError.cacheWriteFailed(error.localizedDescription)
        }
        onLog?("[i4移动端] 手动导入 \(pack.fileName)（bundle id=\(bundleId)）"
               + " · \(fileSize(at: dst.path) / 1024 / 1024) MB")
        return pack
    }

    // MARK: - ④ 安装（定 sinf 来源 → 复制副本 → 注入 → 装副本 → 如实报告）

    /// 安装一个包（移植自爱思 PC 端：**往包里写服务端 sinf，再装那个包**）.
    ///
    /// 流程（每步失败**必抛**，不静默）：
    ///   ① 定位缓存里的 IPA（`Caches/I4MobileIPA/`）；缺失即 `packResourceMissing`
    ///      （**不做隐式下载、不兜底到 bundle**）.
    ///   ② `inspect` 读包内真值；`extractiTunesMetadata` 取 metadata（供 store id 与安装选项）.
    ///   ③ **向服务端现取 sinf**（`NBStoreClient.packageByVersion`）；取不到即
    ///      `serverSinfUnavailable`（**明确失败，不回退到包内自带**）.
    ///   ④ **复制 IPA 到临时目录**（绝不改缓存原件）；复制失败即 `workCopyFailed`.
    ///   ⑤ `PackageSINFWriter.injectAllPaths` 把 sinf 写进副本；失败即 `sinfInjectFailed`.
    ///   ⑥ `IPAInstallService.installWithSINF` 装**副本**（同一份 sinf 作 `ApplicationSINF`）；
    ///      安装失败**原样抛出**（含 `ApplicationVerificationFailed` 等）.
    ///   ⑦ 安装后回读设备，组装 `Report`（含 sinf 账号名等诚实边界）.
    ///
    /// - Parameters:
    ///   - pack: 要安装的包（见 `packs`；IPA 须已在缓存目录，先下载或导入）.
    ///   - allowUpgrade: `true` = 用 `Upgrade` 命令覆盖安装（同 bundle id 已存在时）.
    ///   - progress: 整条链 0~1 的进度回调（AFC 上传段 0~0.75 + installd 段 0.75~1）.
    ///   - onLog: 逐条事实日志回调（调用方可转发到 `LoginLogger`）.
    /// - Returns: `Report`（含 `sinfSource="server"` / `sinfAccountName` / `launchVerified=false` 等）.
    /// - Throws: `I4MobileError` 或底层安装错误.
    @discardableResult
    static func install(pack: Pack,
                        allowUpgrade: Bool = false,
                        progress: (@Sendable (Double) -> Void)? = nil,
                        onLog: (@Sendable (String) -> Void)? = nil) async throws -> Report {
        // ① 定位缓存里的资源.
        guard let url = resolveURL(for: pack) else {
            throw I4MobileError.packResourceMissing(pack.fileName)
        }
        let ipaPath = url.path
        let ipaBytes = fileSize(at: ipaPath)
        onLog?("[i4移动端] 定位 \(pack.fileName)：cache · \(ipaBytes / 1024 / 1024) MB")

        // ② 检测包 + 取 metadata（metadata 既作安装选项，也用于服务端取 sinf 的 store id）.
        let inspection = IPAPackageInspector.inspect(ipaPath: ipaPath)
        let bundleId = inspection?.bundleIdentifier ?? pack.expectedBundleId
        let bundleVersion = inspection?.bundleVersion ?? pack.expectedVersion
        if let inspection {
            onLog?("[i4移动端] 包信息：\(bundleId) \(bundleVersion) · \(inspection.summary)")
        } else {
            onLog?("[i4移动端] 包信息读不出（主二进制 / Info.plist 解析失败），按文件名 \(pack.fileName) 继续")
        }
        let meta = IPAPackageInspector.extractiTunesMetadata(ipaPath: ipaPath)
        onLog?("[i4移动端] 包内 iTunesMetadata：\(meta != nil ? "有" : "无")")

        // ③ 向服务端现取 sinf（只有这一条路；取不到即明确失败，不回退到包内自带）.
        let resolved = try await serverSinf(bundleId: bundleId, metadata: meta, onLog: onLog)
        onLog?("[i4移动端] sinf 来源：服务端现取 · \(resolved.sinf.count) 字节"
               + accountLogSuffix(resolved.account))

        // ④ 复制到临时目录（原件只读，绝不被改写）.
        let workURL = try makeWorkCopy(of: url, fileName: pack.fileName)
        defer { try? FileManager.default.removeItem(at: workURL.deletingLastPathComponent()) }
        onLog?("[i4移动端] 已复制工作副本：\(workURL.lastPathComponent)")

        // ⑤ 把 sinf 写进副本（照爱思：覆盖 SC_Info/*.sinf）.
        let injected: [String]
        do {
            injected = try PackageSINFWriter.injectAllPaths(sinf: resolved.sinf, ipaPath: workURL.path)
        } catch {
            throw I4MobileError.sinfInjectFailed(error.localizedDescription)
        }
        onLog?("[i4移动端] 已把 sinf 写进副本 \(injected.count) 条路径：\(injected.joined(separator: ", "))")

        // ⑥ 安装前探测（best-effort，失败不阻断）.
        let before = await probeDevice(bundleId: bundleId)
        logProbe(before, phase: "安装前", onLog: onLog)

        // ⑦ 安装副本（同一份 sinf 作 ApplicationSINF；阻塞调用放后台）.
        onLog?("[i4移动端] 经 ApplicationSINF 通道安装副本"
               + "（PackageType=Customer, upgrade=\(allowUpgrade)）…")
        let svc = IPAInstallService.shared
        let workPath = workURL.path
        let sinf = resolved.sinf
        try await Task.detached(priority: .userInitiated) {
            try svc.installWithSINF(workPath,
                                    sinf: sinf,
                                    iTunesMetadata: meta,
                                    upgrade: allowUpgrade,
                                    progress: { p in progress?(p) })
        }.value
        onLog?("[i4移动端] installd 已受理安装")

        // ⑧ 安装后回读.
        let after = await probeDevice(bundleId: bundleId)
        logProbe(after, phase: "安装后", onLog: onLog)

        // ⑨ 组装报告.
        let report = buildReport(pack: pack, ipaPath: ipaPath, ipaBytes: ipaBytes,
                                 workIPAPath: workPath, resolution: resolved,
                                 injectedPaths: injected, hasITunesMetadata: meta != nil,
                                 upgrade: allowUpgrade, bundleId: bundleId, bundleVersion: bundleVersion,
                                 before: before, after: after)
        onLog?("[i4移动端] 结论：\(report.verdict)")
        return report
    }

    /// 依次安装全部包（顺序 = `packs`）.
    ///
    /// 诚实边界：**任一步失败即抛错**，不静默跳过后续包 —— 与 `install` 的「每步失败必抛」一致.
    /// 已成功安装的包**不会回滚**（installd 无批量事务）；调用方按返回数组自行处置.
    @discardableResult
    static func installAll(allowUpgrade: Bool = false,
                           progress: (@Sendable (Double) -> Void)? = nil,
                           onLog: (@Sendable (String) -> Void)? = nil) async throws -> [Report] {
        var reports: [Report] = []
        for (idx, pack) in packs.enumerated() {
            onLog?("[i4移动端] (\(idx + 1)/\(packs.count)) 安装 \(pack.fileName)")
            let report = try await install(pack: pack, allowUpgrade: allowUpgrade,
                                           progress: progress, onLog: onLog)
            reports.append(report)
        }
        return reports
    }

    // MARK: - ⑤ UI 对接（`I4MobileInstallView.installAction`）

    /// 生成与 `I4MobileInstallView.installAction`（`() async throws -> Void`）匹配的动作：
    /// **安装全部包**.
    ///
    /// 注：闭包体内用 `_ =` 显式丢弃 `[Report]` 返回值，让闭包返回类型确定为 `Void`
    /// （单表达式闭包会把返回类型推断成 `[Report]`，与 UI 期望的 `Void` 不符）.
    static func makeInstallAllAction(allowUpgrade: Bool = false,
                                     progress: (@Sendable (Double) -> Void)? = nil,
                                     onLog: (@Sendable (String) -> Void)? = nil) -> () async throws -> Void {
        return {
            _ = try await installAll(allowUpgrade: allowUpgrade,
                                     progress: progress, onLog: onLog)
        }
    }

    /// 生成只安装指定包的动作用于 UI.
    static func makeInstallAction(pack: Pack,
                                  allowUpgrade: Bool = false,
                                  progress: (@Sendable (Double) -> Void)? = nil,
                                  onLog: (@Sendable (String) -> Void)? = nil) -> () async throws -> Void {
        return {
            _ = try await install(pack: pack, allowUpgrade: allowUpgrade,
                                  progress: progress, onLog: onLog)
        }
    }

    // MARK: - ⑧ 自动选包（移植爱思「安装移动端」的瀑布降级选择）

    /// 选包输入：设备画像（iOS 版本 + 机型 + 已装 App 的 bundle id 集合）.
    ///
    /// 为什么是这三项：爱思的选择函数 `0x1401db840` 的输入只有 **iOS 版本**（`[this+0x88]`）
    /// 与 **机型**（`[this+0x128]`）；「已装列表」用于 ⓪ 层短路（见 `autoPick`）.
    struct DeviceProfile: Sendable {
        /// 设备 iOS 版本（如 `15.1`）；来源 = `DeviceInfoModel.systemVersion`.
        let iosVersion: String
        /// 机型（`hw.machine`，如 `iPhone13,1`）；来源 = `DeviceInfoModel.productType`.
        let model: String
        /// 设备已装 App 的 bundle id 集合（best-effort；读不到时为空集合）.
        let installedBundleIds: Set<String>
    }

    /// 瀑布档位（照爱思 `0x1401db840` 的判定顺序；命中即停）.
    ///
    /// ⚠️ `alreadyInstalledMain`（⓪）**不产出包体**，只做短路判定（跳过 ① 直接进 ②），
    /// 故它不会是 `AutoPick.tier` 的**结果**档位，保留仅为让瀑布顺序自解释.
    enum Tier: String, Sendable {
        /// ⓪ 设备已装 `com.ownbook.notes`（爱思移动端主 App）⇒ 短路跳过 ①，直接进 ②.
        case alreadyInstalledMain
        /// ① iOS ≥ 15.1 且 `v9items["305"].policy ≠ 0` → 305（com.best.vaultnotes）.
        case ios15_1
        /// ② iOS ≥ 13.0 → 220（com.ownbook.notes）.
        case ios13_0
        /// ③ iOS ≥ 10.0 → 217（rn.notes.best）.
        case ios10_0
        /// ④ iOS ≥ 9.0 且机型 == `iPhone4,1` → 213（com.pd.A4Player）.
        case ios9_0_iphone41
        /// ⑤ 兜底 → 723（com.diary.mood）.
        case fallback

        /// 档位依据（UI 展示用；中文，标点用英文句点）.
        var basis: String {
            switch self {
            case .alreadyInstalledMain: return "已装 com.ownbook.notes"
            case .ios15_1: return "iOS ≥ 15.1"
            case .ios13_0: return "iOS ≥ 13.0"
            case .ios10_0: return "iOS ≥ 10.0"
            case .ios9_0_iphone41: return "iOS ≥ 9.0 且机型 iPhone4,1"
            case .fallback: return "兜底（以上档位都不满足）"
            }
        }
    }

    /// 自动选包结果（如实：选中的包体或「无可用」，并附逐档判定轨迹）.
    struct AutoPick: Sendable {
        let profile: DeviceProfile
        /// 选中的档位；`pack == nil` 时为瀑布落到的最后一档.
        let tier: Tier
        /// 选中的包体；`nil` = 该档位在本仓**无对应 IPA**（不假装可用）.
        let pack: Pack?
        /// ⓪ 是否命中（设备已装 `com.ownbook.notes`）.
        let alreadyInstalledMain: Bool
        /// 逐档判定轨迹（供 UI 说明「为什么落到这一档」；每行一个事实）.
        let trace: [String]

        /// 是否选出了可用包体.
        var hasPack: Bool { pack != nil }
    }

    /// 按爱思的瀑布顺序（⓪①②③④⑤）选一个包体.
    ///
    /// ## 判定顺序（严格照 `0x1401db840`）
    /// ⓪ 设备已装 `com.ownbook.notes` ⇒ 短路跳过 ①，直接进 ②.
    /// ① iOS ≥ 15.1 **且** `v9items["305"].policy ≠ 0` → 305（com.best.vaultnotes）.
    /// ② iOS ≥ 13.0 → 220（com.ownbook.notes）.
    /// ③ iOS ≥ 10.0 → 217（rn.notes.best）.
    /// ④ iOS ≥ 9.0 且机型 == `iPhone4,1` → 213（com.pd.A4Player）.
    /// ⑤ 兜底 → 723（com.diary.mood）.
    ///
    /// ## 本仓的诚实边界（不发明、不假装）
    /// - 本仓内置包只有 `220` / `217` / `photo`（`photo` 不在瀑布内，是爱思的独立「相册/文件」
    ///   分支）；`305` / `213` / `723` **均无包体** ⇒ ①④⑤ 命中条件时**如实回落**（与爱思
    ///   `policy==0` 时从 ① 落到 ② 的行为一致），不伪造、不借别的包顶替.
    /// - `v9items` 是爱思服务端下发的配置数组（含 `policy`）；本仓**没有** `v9items`，故 ① 的
    ///   `policy ≠ 0` 条件**无法评估** ⇒ 按「该档位不可用」处理并回落.
    /// - ①④⑤ 无包体时不报「装不了」，而是**继续按爱思顺序往下一档走**；全部落空才返回
    ///   `pack == nil`（调用方据此如实显示「无可用包体」）.
    ///
    /// ## 纯函数
    /// 只读入参、无副作用、不触设备 ⇒ 可离线单测（输入 `DeviceProfile`，输出 `AutoPick`）.
    static func autoPick(profile: DeviceProfile) -> AutoPick {
        var trace: [String] = []
        let installedMain = profile.installedBundleIds.contains("com.ownbook.notes")

        // ⓪ 已装 com.ownbook.notes ⇒ 跳过 ①，直接进 ②（照爱思 0x1401dbac9 jne 0x1401dbb38）.
        if installedMain {
            trace.append("本机已装 com.ownbook.notes，按爱思做法跳过 iOS ≥ 15.1 档，直接进 iOS ≥ 13.0 档.")
        }

        // ① iOS ≥ 15.1 且 v9items["305"].policy ≠ 0 → 305.
        // ⓪ 命中时不评估 ①；否则评估：本仓无 305 包体、且无 v9items ⇒ 该档位不可用，回落.
        if !installedMain, compareVersion(profile.iosVersion, "15.1") >= 0 {
            if let p = pack(forBundleId: "com.best.vaultnotes") {
                return AutoPick(profile: profile, tier: .ios15_1, pack: p,
                                alreadyInstalledMain: installedMain, trace: trace)
            }
            trace.append("iOS ≥ 15.1 档需 305（com.best.vaultnotes），本仓无该包体，"
                         + "且无 v9items 配置（policy 条件无法评估），按爱思做法回落.")
        }

        // ② iOS ≥ 13.0 → 220.
        if compareVersion(profile.iosVersion, "13.0") >= 0 {
            if let p = pack(forBundleId: "com.ownbook.notes") {
                return AutoPick(profile: profile, tier: .ios13_0, pack: p,
                                alreadyInstalledMain: installedMain, trace: trace)
            }
            trace.append("iOS ≥ 13.0 档需 220（com.ownbook.notes），本仓无该包体，回落.")
        }

        // ③ iOS ≥ 10.0 → 217.
        if compareVersion(profile.iosVersion, "10.0") >= 0 {
            if let p = pack(forBundleId: "rn.notes.best") {
                return AutoPick(profile: profile, tier: .ios10_0, pack: p,
                                alreadyInstalledMain: installedMain, trace: trace)
            }
            trace.append("iOS ≥ 10.0 档需 217（rn.notes.best），本仓无该包体，回落.")
        }

        // ④ iOS ≥ 9.0 且机型 == iPhone4,1 → 213.
        if compareVersion(profile.iosVersion, "9.0") >= 0, profile.model == "iPhone4,1" {
            if let p = pack(forBundleId: "com.pd.A4Player") {
                return AutoPick(profile: profile, tier: .ios9_0_iphone41, pack: p,
                                alreadyInstalledMain: installedMain, trace: trace)
            }
            trace.append("iOS ≥ 9.0 且机型 iPhone4,1 档需 213（com.pd.A4Player），本仓无该包体，回落.")
        }

        // ⑤ 兜底 → 723.
        trace.append("兜底档需 723（com.diary.mood），本仓无该包体，无可用包体.")
        return AutoPick(profile: profile, tier: .fallback, pack: nil,
                        alreadyInstalledMain: installedMain, trace: trace)
    }

    /// 在本仓**内置包**里按 bundle id 找包体（自定义包体不参与瀑布 —— 瀑布是爱思内置集合的语义）.
    private static func pack(forBundleId bundleId: String) -> Pack? {
        packs.first { $0.expectedBundleId == bundleId }
    }

    /// 比较两个点分版本号（如 `"15.1"` vs `"13.0"`）；`a` 小于 / 等于 / 大于 `b` 返回 -1 / 0 / 1.
    ///
    /// 逐段按整数比；缺段按 0；非数字段取前缀数字（取不到按 0）—— 不抛错，尽量给出可比结果.
    static func compareVersion(_ a: String, _ b: String) -> Int {
        let pa = versionParts(a), pb = versionParts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    private static func versionParts(_ s: String) -> [Int] {
        s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// 读设备已装 App 的 bundle id 集合（best-effort；读不到返回空集合，不抛错）.
    ///
    /// 阻塞调用（建 RSD 隧道 + instproxy 枚举），放后台；只把 Sendable 的 `Set<String>` 带回边界
    /// （与 `probeDevice` 同一模式）.
    static func installedBundleIds() async -> Set<String> {
        await Task.detached(priority: .utility) {
            guard let apps = try? AppDiscovery().fetchInstalledApps() else { return Set<String>() }
            return Set(apps.map(\.bundleIdentifier))
        }.value
    }

    /// 用已读到的设备 iOS 版本 + 机型补上「已装列表」，组装瀑布输入 `DeviceProfile`.
    ///
    /// iOS 版本 / 机型来自 `DeviceInfoModel`（`DeviceInfoService.collectFull()` 读出的
    /// `systemVersion` / `productType`，本 App 运行在设备上，即为本机值），调用方（UI）已有，
    /// 无需重复读设备；此处只补一次「已装列表」（best-effort）.
    static func deviceProfile(iosVersion: String, model: String) async -> DeviceProfile {
        let installed = await installedBundleIds()
        return DeviceProfile(iosVersion: iosVersion, model: model, installedBundleIds: installed)
    }

    // MARK: - ⑥ 向服务端现取 sinf（只有这一条路）

    /// 向 NB 服务端按版本现取 sinf.
    ///
    /// 取不到（无 metadata / 缺 store id / 服务端没回 sinf / 结构不合法）一律抛
    /// `serverSinfUnavailable` —— **不回退到包内自带**（包内 sinf 属原始购买者，
    /// 用它会把「装上但闪退」变成常态）.
    private static func serverSinf(bundleId: String, metadata: Data?,
                                   onLog: (@Sendable (String) -> Void)?) async throws -> SinfResolution {
        guard let metadata else {
            throw I4MobileError.serverSinfUnavailable(reason: "包内无 iTunesMetadata，拿不到 itemId / appVerId")
        }
        let identity = storeIdentity(from: metadata)
        guard let itemId = identity.itemId, let appVerId = identity.appVerId else {
            throw I4MobileError.serverSinfUnavailable(
                reason: "metadata 缺 store id（itemId=\(identity.itemId ?? "无") appVerId=\(identity.appVerId ?? "无")）")
        }
        onLog?("[i4移动端] 向服务端取 sinf：appID=\(itemId) appVerId=\(appVerId)")
        let pkg = try await NBStoreClient.packageByVersion(appID: itemId, appVerId: appVerId,
                                                            bundleID: bundleId)
        guard let b64 = pkg?.sinfBase64, !b64.isEmpty else {
            throw I4MobileError.serverSinfUnavailable(reason: "服务端响应未含 sinf")
        }
        guard let data = Data(base64Encoded: b64), PackageSINFWriter.isStructurallyValidSinf(data) else {
            throw I4MobileError.serverSinfUnavailable(reason: "服务端 sinf 不是合法 base64 / 结构不合法")
        }
        return SinfResolution(sinf: data, account: parseSinfAccount(data))
    }

    /// 从 `iTunesMetadata.plist` 读 `itemId`（trackId）与 `softwareVersionExternalIdentifier`.
    static func storeIdentity(from metadata: Data) -> (itemId: String?, appVerId: String?) {
        guard let plist = try? PropertyListSerialization.propertyList(from: metadata, options: [], format: nil),
              let dict = plist as? [String: Any] else { return (nil, nil) }
        return (stringValue(dict["itemId"]),
                stringValue(dict["softwareVersionExternalIdentifier"]))
    }

    // MARK: - ⑦ schi 解析（sinf 里「这份授权属于谁」）

    /// 解析 sinf 里的 `schi` 块，取账号名 / user / crdt.
    ///
    /// ## 结构（TLV 块式）
    /// 顶层：`{4B 大端总长}` + `"sinf"` + 块序列；每块 `{4B 大端块长}{4B tag}{body}`
    /// （**块长含 8 字节头**；前 4 字节是**长度**不是固定魔数）。顶层块为
    /// `frma / schm / schi / sign`。`schi` 的 body 同样是**裸子块序列**，其中：
    ///   · `user`：4 字节账号标识；`crdt`：4 字节凭据标识；`name`：UTF-8 定长、NUL 补齐.
    /// 实测（本仓 `Resources/I4Mobile/` 三包）：`217 → 李 明 / 0xab6d95d8`，
    /// `220 → 小 敏 / 0xa775eea7`，`photo → chongwei stven / 0xab5c9f49`.
    ///
    /// - Returns: 解析结果；非 sinf 结构 / 无 `schi` 时为 `nil`.
    static func parseSinfAccount(_ sinf: Data) -> SinfAccount? {
        let b = [UInt8](sinf)
        guard b.count >= 8, Array(b[4..<8]) == Array("sinf".utf8),
              let schiSlice = chunkBody(b, from: 8, to: b.count, tag: "schi") else { return nil }
        let schi = Array(schiSlice)
        var name: String?
        if let body = chunkBody(schi, from: 0, to: schi.count, tag: "name") {
            name = String(bytes: body.prefix { $0 != 0 }, encoding: .utf8)
        }
        let user = chunkBody(schi, from: 0, to: schi.count, tag: "user").map(hexString)
        let crdt = chunkBody(schi, from: 0, to: schi.count, tag: "crdt").map(hexString)
        return SinfAccount(name: name, userHex: user, crdtHex: crdt)
    }

    /// 在 `{4B 块长}{4B tag}{body}` 块序列里找第一个 tag 匹配块的 body.
    private static func chunkBody(_ b: [UInt8], from start: Int, to end: Int,
                                  tag: String) -> ArraySlice<UInt8>? {
        let tagBytes = Array(tag.utf8)
        var off = start
        while off + 8 <= end {
            let len = Int(be32(b, off))
            guard len >= 8, off + len <= end else { break }
            if Array(b[(off + 4)..<(off + 8)]) == tagBytes {
                return b[(off + 8)..<(off + len)]
            }
            off += len
        }
        return nil
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16)
             | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    private static func hexString(_ bytes: ArraySlice<UInt8>) -> String {
        "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 内部

    /// 复制 IPA 到唯一临时目录，返回副本 URL（调用方负责删除其父目录）.
    private static func makeWorkCopy(of url: URL, fileName: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("I4MobileWork-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw I4MobileError.workCopyFailed(error.localizedDescription)
        }
        let dst = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: url, to: dst)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw I4MobileError.workCopyFailed(error.localizedDescription)
        }
        return dst
    }

    /// 设备探测（best-effort）：读已装应用 → 同名 App 版本；失败如实记 error.
    ///
    /// 阻塞调用（建 RSD 隧道 + instproxy 枚举），放后台；只把纯值（`DeviceProbe`）带回边界，
    /// 非 Sendable 的 `AppDiscovery` / `[InstalledApp]` 不跨边界.
    static func probeDevice(bundleId: String) async -> DeviceProbe {
        await Task.detached(priority: .utility) {
            do {
                let apps = try AppDiscovery().fetchInstalledApps()
                let existing = apps.first { $0.bundleIdentifier == bundleId }?.version
                return DeviceProbe(existingVersion: existing, error: nil)
            } catch {
                return DeviceProbe(existingVersion: nil, error: error.localizedDescription)
            }
        }.value
    }

    /// 组装如实报告（含 sinf 账号名等诚实边界与启动风险）.
    private static func buildReport(pack: Pack, ipaPath: String, ipaBytes: Int,
                                    workIPAPath: String, resolution: SinfResolution,
                                    injectedPaths: [String], hasITunesMetadata: Bool, upgrade: Bool,
                                    bundleId: String, bundleVersion: String,
                                    before: DeviceProbe, after: DeviceProbe) -> Report {
        // 安装后回读确认（探测失败 = nil，不当成「没装上」）.
        let confirmed: Bool? = after.error != nil ? nil : (after.existingVersion != nil)

        var notes: [String] = []
        notes.append("sinf 来源：服务端现取并覆盖包内（本服务只有这一条路）.")
        if let account = resolution.account {
            notes.append("sinf 的 schi.name=\(account.name ?? "?")，schi.user=\(account.userHex ?? "?")，"
                         + "schi.crdt=\(account.crdtHex ?? "?")：这是该授权所属的账号.")
        } else {
            notes.append("sinf 的 schi 未解析出账号信息（结构可能非标准）.")
        }
        notes.append("sinf 由服务端按版本现取并覆盖包内；是否已授权本机仍无法验证.")
        notes.append("本服务只做安装，不验证启动：install 成功不等于能启动.")
        if confirmed == false {
            notes.append("安装后未在设备上回读到该 bundle id（\(bundleId)），"
                         + "可能安装未落盘，或探测不可靠（隧道 / 权限）.")
        }

        let mayCrash = (confirmed == false)
        let verdict: String
        if confirmed == false {
            verdict = "已向 installd 递交安装，但未回读到该 App，安装结果存疑."
        } else {
            verdict = "已安装 \(bundleId) \(bundleVersion)，sinf 来自服务端；启动未验证."
        }

        return Report(pack: pack, ipaPath: ipaPath, ipaBytes: ipaBytes, workIPAPath: workIPAPath,
                      sinfSource: "server",
                      sinfAccountName: resolution.account?.name,
                      sinfAccountUser: resolution.account?.userHex,
                      sinfBytes: resolution.sinf.count, injectedPaths: injectedPaths,
                      hasITunesMetadata: hasITunesMetadata, upgrade: upgrade,
                      bundleId: bundleId, bundleVersion: bundleVersion,
                      before: before, after: after,
                      installedConfirmed: confirmed,
                      launchVerified: false, mayCrashAtLaunch: mayCrash,
                      notes: notes, verdict: verdict)
    }

    /// 把探测结果写进日志（只写事实，不解释）.
    private static func logProbe(_ probe: DeviceProbe, phase: String,
                                 onLog: (@Sendable (String) -> Void)?) {
        if let error = probe.error {
            onLog?("[i4移动端] \(phase)探测失败：\(error)")
            return
        }
        onLog?("[i4移动端] \(phase)探测：同名 App 版本=\(probe.existingVersion ?? "未安装")")
    }

    /// 账号信息拼成日志后缀（无解析结果时为空串）.
    private static func accountLogSuffix(_ account: SinfAccount?) -> String {
        guard let account else { return "" }
        return " · schi.name=\(account.name ?? "?") schi.user=\(account.userHex ?? "?")"
    }

    /// plist 值为字符串 / 数字时统一成字符串.
    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    /// 文件大小（读不到返回 0）.
    private static func fileSize(at path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
