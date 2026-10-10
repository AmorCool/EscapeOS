import Foundation
import CommonCrypto
import SystemConfiguration

/// 爱思「安装移动端」服务层（只做逻辑，不含 UI）—— 移植自爱思助手 PC 端 9.0.
///
/// ## IPA 从哪来（v4：两条云端 + 手动导入）
/// 本服务**不再读 app bundle 里的内嵌 IPA**，来源共**三条**（用户指定），都落盘到同一个缓存目录
/// `Caches/I4MobileIPA/`：
///   ① **仓库云端** —— `downloadCloudIPA(pack:from:.warehouse)` 按 `pack.cloudURL` 下到缓存目录；
///   ② **爱思云端** —— `downloadCloudIPA(pack:from:.i4)` 经注入的 `I4CloudResolver` 解析地址后下载
///      （默认实现 `I4CloudResolverImpl`，按已挖清的契约走 `app4.i4.cn` 的 3DES 接口，见下）；
///   ③ **手动导入** —— `importIPA(from:)` 把用户选中的 IPA 拷进缓存目录.
/// 安装时**只认缓存目录**（`resolveURL`）；缓存缺失即 `packResourceMissing`，
/// **不做隐式下载、不兜底到 bundle** —— 用户明确要求去掉「内置进 app bundle」.
///
/// `pack.cloudURL` = **仓库云端**直链（模块仓库 `AmorCool/module-esc` 的 `edge` Release），
/// 三个包均已填好（见 `P3_爱思助手_逆向/_简报/实现_模块仓库托管IPA.md` ④，下载后 md5 已核）.
///
/// **爱思云端**接口（`app4.i4.cn/getipaformobiledevice.xhtml`）的请求 / 响应契约已由逆向坐实
/// （见 `P3_爱思助手_逆向/_简报/逆向_爱思云端下载IPA接口.md`）：`POST` + 3DES-ECB + Base64 + URL 转义.
/// 真实现 = `I4CloudResolverImpl`（**默认**）；`UnavailableI4CloudResolver` 保留作**降级 / 测试**用
/// （显式传它即让爱思云端一律不可用）.
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
/// 重取路径 `WriteAppSignature start` → 轮询 → 下载解析 → `addSinfToZip`。
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
        let expectedBundleId: String
        /// 期望版本（仅供参考，实际以包内 Info.plist 为准）.
        let expectedVersion: String
        /// **仓库云端**下载直链（模块仓库 `edge` Release）. 空串 = 未配置.
        let cloudURL: String
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

    /// 云端下载来源（用户可选）—— **只有这两条**（用户指定），不增第三条.
    ///
    ///   · `.warehouse` 仓库云端 —— 本模块仓库 `AmorCool/module-esc` 的 `edge` Release 直链
    ///     （`pack.cloudURL`，URL 已知）；
    ///   · `.i4` 爱思云端 —— 爱思自家服务端接口 `app4.i4.cn/getipaformobiledevice.xhtml`
    ///     （契约已坐实，由 `I4CloudResolverImpl` 解析；需设备 UDID）.
    enum CloudSource: String, CaseIterable, Identifiable, Sendable {
        case warehouse
        case i4

        var id: String { rawValue }

        /// 展示名（界面用；中文，标点用英文句点）.
        var displayName: String {
            switch self {
            case .warehouse: return "仓库云端"
            case .i4: return "爱思云端"
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

    /// 爱思云端下载解析器（**可注入**）.
    ///
    /// ## 为什么是协议
    /// 爱思云端接口的请求 / 响应契约已由逆向坐实（见
    /// `P3_爱思助手_逆向/_简报/逆向_爱思云端下载IPA接口.md`）。真实现 `I4CloudResolverImpl`
    /// 是**默认**；`UnavailableI4CloudResolver` 保留作**降级 / 测试**用（显式传入即让爱思云端
    /// 一律不可用，便于离线开发与对照）。
    ///
    /// ## 为什么 `downloadURL` 是 `async`
    /// 真实现要发一次 HTTPS 请求（秒级）；本仓开启 SE-0461（`nonisolated` async 默认跟随调用方
    /// executor），若做成同步，从 `MainActor` 调进来会**阻塞主线程**。改成 `async` 后由
    /// `URLSession` 的异步 API 承担，主线程不被占住。`availability` 保持同步且**零阻塞**
    /// （只读进程内缓存 + 廉价本地探测）。
    protocol I4CloudResolver: Sendable {
        /// 该包在爱思云端是否可用（不可用须给原因，UI 如实显示）.
        func availability(for pack: Pack) -> CloudAvailability
        /// 解析该包的爱思云端下载地址；不可用抛 `I4MobileError.cloudSourceUnavailable`.
        func downloadURL(for pack: Pack) async throws -> URL
    }

    /// **降级 / 测试**用实现：对一切包返回 `.unavailable`（不猜地址）。默认**不是**它.
    struct UnavailableI4CloudResolver: I4CloudResolver {
        func availability(for pack: Pack) -> CloudAvailability {
            .unavailable(reason: "爱思云端已按降级开关关闭（UnavailableI4CloudResolver）.")
        }

        func downloadURL(for pack: Pack) async throws -> URL {
            throw I4MobileError.cloudSourceUnavailable(
                pack: pack.fileName, source: CloudSource.i4.displayName,
                reason: "爱思云端已按降级开关关闭（UnavailableI4CloudResolver）.")
        }
    }

    /// **爱思云端的真实实现** —— 协议层照 `逆向_爱思云端下载IPA接口.md` 逐条落地，不发明字段.
    ///
    /// ## 请求（严格照契约）
    ///   · 端点：`POST https://app4.i4.cn/getipaformobiledevice.xhtml?pcver=9.09.026`
    ///     （测试域 `test-app4.i4.cn` 只在爱思客户端内部调试时用，此处走生产域）.
    ///   · 头：`Content-Type: application/json`（契约如此；**体并不是 JSON**，见下）.
    ///   · 体：`urlencode(base64(3DES_ECB_PKCS7(json, key)))`
    ///     —— 3DES-**ECB**（无 IV / 无链式）、PKCS#7 填充、Base64、逐字节 `%XX` URL 转义.
    ///   · key：`2014aisi1234567890mobileclient29`，**只取前 24 字节**（`DESStream3` ctor 截断）.
    ///   · JSON：`{"apps":[{udid,model,ios,bundleid,md5,versionid,shortversion,longversion}]}`.
    ///
    /// ## 请求 JSON 字段来源
    ///   · `udid`  —— 设备真实 UDID（`LocalDeviceIdentity` 的进程内缓存；冷缓存才真读一次，且放在
    ///     后台任务里，不占主线程）.
    ///   · `model` —— `hw.machine`（如 `iPhone13,1`，与 lockdown `ProductType` 同值）.
    ///   · `ios`   —— `ProcessInfo.processInfo.operatingSystemVersion` 拼成的版本串
    ///     （本 App 与目标设备同机，值一致；与 `DeviceInfoService.systemVersion` 同源）.
    ///   · `bundleid` / `shortversion` / `longversion` —— 取自 `Pack`
    ///     （`expectedBundleId` / `expectedVersion`；我们只有一个版本串，两处同值）.
    ///   · `md5` / `versionid` —— **恒为空串**（照客户端行为：`versionid` 客户端恒空；
    ///     `md5` 客户端取自本地应用对象，我们无该对象 ⇒ 留空，由服务端按设备选版本）.
    ///
    /// ## 响应（逐字段按契约）
    ///   · 顶层 `code`：**`== 0` 才处理 `data`**；非 0 即抛（带 code）.
    ///   · `data.apps[0].status`：**只有 `2` 才带 `url`**（下载直链，**原样使用，不拼接 / 不改写**）；
    ///     `1` / `3` / 其它一律抛错并带 `msg`（**不静默回落到仓库云端** —— 用户选了哪条就哪条）.
    ///
    /// ## 诚实边界（未实测；**写进注释与简报，不写成 UI 免责长文**）
    ///   · 该接口**是否真能免账号拿到 `.ipa`** 未真机实测（逆向报告结论：须真机实测）.
    ///   · 拿到的 `url` 是否**绑定 UDID / 有时效 / 有 IP 限制**未知 ⇒ 能否直接 GET 到 `.ipa` 未验证.
    ///   · 爱思私有加密接口、无版本协商 ⇒ 服务端随时可改；`urlencode` 的确切转义集也未见动态验证.
    struct I4CloudResolverImpl: I4CloudResolver {

        // MARK: 契约常量（逆向取得，照抄不改）

        /// 端点（生产域）.
        static let endpoint = "https://app4.i4.cn/getipaformobiledevice.xhtml?pcver=9.09.026"
        /// 3DES key（客户端硬编码；`DESStream3` ctor 只取**前 24 字节**）.
        static let desKey = "2014aisi1234567890mobileclient29"
        /// key 截断长度（3DES 密钥长度）.
        static let desKeyLength = 24

        // MARK: 可用性（同步、零阻塞）

        /// 可用性判据（**不假装可用**）：
        ///   ① 无 bundle id ⇒ 不可用；
        ///   ② 读不到设备 UDID ⇒ 不可用（并顺手后台预热，下一次可能就绪）；
        ///   ③ 无网络 ⇒ 不可用；
        ///   ④ 否则 ⇒ 可用.
        func availability(for pack: Pack) -> CloudAvailability {
            guard !pack.expectedBundleId.isEmpty else {
                return .unavailable(reason: "该包未配置 bundle id.")
            }
            guard let udid = Self.cachedUDID(), !udid.isEmpty else {
                // 冷缓存：**不阻塞**，挂后台预热；本次如实报不可用.
                LocalDeviceIdentity.warmUpInBackground()
                return .unavailable(reason: "读不到设备 UDID（设备身份缓存未就绪，请稍后重试）.")
            }
            guard Self.networkReachable() else {
                return .unavailable(reason: "网络不可用（当前无可用网络连接）.")
            }
            return .available(detail: "需设备 UDID · 第三方来源.")
        }

        // MARK: 解析下载地址

        /// 按契约取该包的下载直链；任一步失败即抛 `cloudSourceUnavailable`（含原因），**不静默**.
        func downloadURL(for pack: Pack) async throws -> URL {
            guard !pack.expectedBundleId.isEmpty else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "该包未配置 bundle id.")
            }
            // udid：优先进程内缓存；冷缓存才真读一次（放后台任务，不占主线程）.
            var udid = Self.cachedUDID()
            if udid == nil {
                udid = await Task.detached(priority: .utility) { I4CloudResolverImpl.readUDID() }.value
            }
            guard let udid, !udid.isEmpty else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "读不到设备 UDID（设备身份不可用）.")
            }

            let json = try Self.buildRequestJSON(pack: pack, udid: udid)
            let body = try Self.encryptedBody(json: json, pack: pack)
            let data = try await Self.post(body: body, pack: pack)
            let entry = try Self.parseResponse(data, pack: pack)

            // status == 2 才带 url；其它值（含 1 / 3 / 未知）如实抛错并带 msg.
            guard entry.status == 2 else {
                let msgSuffix = entry.msg.map { " · msg=\($0)" } ?? ""
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "服务端 status=\(entry.status)\(msgSuffix).")
            }
            guard let raw = entry.url, !raw.isEmpty, let url = URL(string: raw) else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "服务端 status=2 但未给出可用的 url.")
            }
            return url
        }

        // MARK: 请求构造

        /// 组请求 JSON：`{"apps":[{udid,model,ios,bundleid,md5,versionid,shortversion,longversion}]}`.
        static func buildRequestJSON(pack: Pack, udid: String) throws -> String {
            let app: [String: Any] = [
                "udid": udid,
                "model": hardwareModel(),
                "ios": osVersion(),
                "bundleid": pack.expectedBundleId,
                "md5": "",
                "versionid": "",
                "shortversion": pack.expectedVersion,
                "longversion": pack.expectedVersion,
            ]
            let root: [String: Any] = ["apps": [app]]
            guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "请求 JSON 编码失败.")
            }
            return text
        }

        /// `urlencode(base64(3DES_ECB_PKCS7(plain, key)))`.
        static func encryptedBody(json: String, pack: Pack) throws -> String {
            guard let plain = json.data(using: .utf8) else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "请求 JSON 非 UTF-8.")
            }
            let key = Data(desKey.utf8).prefix(desKeyLength)     // 截前 24 字节
            guard key.count == desKeyLength, let cipher = encrypt3DESECB(plain, key: Data(key)) else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "3DES 加密失败.")
            }
            let base64 = cipher.base64EncodedString()
            guard let encoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "URL 转义失败.")
            }
            return encoded
        }

        /// 3DES-**ECB** + PKCS#7（`CommonCrypto`，与客户端 `DESStream3` 同款：ECB、无 IV）.
        static func encrypt3DESECB(_ plain: Data, key: Data) -> Data? {
            let outCap = plain.count + kCCBlockSize3DES
            var out = Data(count: outCap)
            var moved = 0
            let status = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
                plain.withUnsafeBytes { inBuf in
                    key.withUnsafeBytes { keyBuf in
                        CCCrypt(CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithm3DES),
                                CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                                keyBuf.baseAddress, key.count,
                                nil,                              // ECB：无 IV
                                inBuf.baseAddress, plain.count,
                                outBuf.baseAddress, outCap,
                                &moved)
                    }
                }
            }
            guard status == kCCSuccess else { return nil }
            out.removeSubrange(moved..<out.count)
            return out
        }

        // MARK: 网络

        /// 发 POST，返回响应体原始字节；HTTP 非 2xx 即抛.
        static func post(body: String, pack: Pack) async throws -> Data {
            guard let url = URL(string: endpoint) else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "端点 URL 非法.")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data(using: .utf8)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw I4MobileError.cloudSourceUnavailable(
                        pack: pack.fileName, source: CloudSource.i4.displayName,
                        reason: "服务端返回 HTTP \(http.statusCode).")
                }
                return data
            } catch let e as I4MobileError {
                throw e
            } catch {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "请求失败：\(error.localizedDescription)")
            }
        }

        // MARK: 响应解析

        /// 一条 `data.apps[i]` 的解析结果（只取解析下载地址所需的字段）.
        struct ResponseEntry: Sendable {
            let status: Int
            let msg: String?
            let url: String?
        }

        /// 解析响应：校验 `code == 0`，取 `data.apps[0]`；结构不合法即抛.
        static func parseResponse(_ data: Data, pack: Pack) throws -> ResponseEntry {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "响应不是合法 JSON.")
            }
            let code = (root["code"] as? NSNumber)?.intValue ?? -1
            guard code == 0 else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "服务端 code=\(code).")
            }
            guard let dataDict = root["data"] as? [String: Any],
                  let apps = dataDict["apps"] as? [[String: Any]],
                  let first = apps.first else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.i4.displayName,
                    reason: "响应缺 data.apps.")
            }
            let status = (first["status"] as? NSNumber)?.intValue ?? -1
            return ResponseEntry(status: status,
                                 msg: first["msg"] as? String,
                                 url: first["url"] as? String)
        }

        // MARK: 设备参数

        /// 进程内缓存的 UDID（**绝不建隧道**）；冷缓存返回 nil.
        static func cachedUDID() -> String? {
            guard let snap = LocalDeviceIdentity.cachedSnapshot() else { return nil }
            let udid = snap.udid?.trimmingCharacters(in: .whitespaces)
            return (udid?.isEmpty == false) ? udid : nil
        }

        /// 真读一次 UDID（**会建隧道，秒级**）—— 只在下载链路的后台任务里调用.
        static func readUDID() -> String? {
            let snap = LocalDeviceIdentity.load()
            let udid = snap.udid?.trimmingCharacters(in: .whitespaces)
            return (udid?.isEmpty == false) ? udid : nil
        }

        /// `hw.machine`（设备机型标识，如 `iPhone13,1`）；读不到返回空串.
        static func hardwareModel() -> String {
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            guard size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.machine", &buf, &size, nil, 0)
            return String(cString: buf)
        }

        /// 设备 iOS 版本串（`major.minor.patch`）.
        static func osVersion() -> String {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }

        /// 廉价的同步可达性探测（零地址，不做 DNS）：无可用网络连接时返回 `false`.
        ///
        /// 判不出（建不出句柄 / 取不到 flags）时**返回 `true`** —— 宁可让下载去试，
        /// 也不误报「不可用」.
        static func networkReachable() -> Bool {
            var zero = sockaddr_in()
            zero.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            zero.sin_family = sa_family_t(AF_INET)
            let reach = withUnsafePointer(to: &zero) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    SCNetworkReachabilityCreateWithAddress(nil, $0)
                }
            }
            guard let reach else { return true }
            var flags = SCNetworkReachabilityFlags()
            guard SCNetworkReachabilityGetFlags(reach, &flags) else { return true }
            return flags.contains(.reachable)
        }
    }

    /// 一个包的**缓存就位情况 + 两条云端各自的可用性**（供 UI 展示；只查本地文件，不读设备）.
    struct PackStatus: Identifiable, Sendable {
        let pack: Pack
        /// 缓存目录里是否已有该 IPA（且非空）.
        let cached: Bool
        /// 已缓存 IPA 的字节数（未缓存为 0）.
        let bytes: Int
        /// **仓库云端**可用性（`cloudURL` 非空且可解析为 URL 即可用）.
        let warehouseAvailability: CloudAvailability
        /// **爱思云端**可用性（由注入的 resolver 决定；默认不可用）.
        let i4Availability: CloudAvailability
        var id: String { pack.fileName }

        /// 按来源取该包的可用性.
        func availability(of source: CloudSource) -> CloudAvailability {
            switch source {
            case .warehouse: return warehouseAvailability
            case .i4: return i4Availability
            }
        }
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

    /// 列出各包缓存是否就位 + 两条云端各自的可用性（供 UI 展示）.
    ///
    /// - Parameter resolver: 爱思云端解析器（**默认真实现** `I4CloudResolverImpl`；可注入降级实现）.
    static func packStatuses(resolver: I4CloudResolver = I4CloudResolverImpl()) -> [PackStatus] {
        packs.map { pack in
            let bytes = fileSize(at: cachedIPAURL(for: pack).path)
            let warehouse: CloudAvailability =
                (!pack.cloudURL.isEmpty && URL(string: pack.cloudURL) != nil)
                ? .available(detail: pack.cloudURL)
                : .unavailable(reason: "未配置仓库 Release 直链.")
            return PackStatus(pack: pack, cached: bytes > 0, bytes: bytes,
                              warehouseAvailability: warehouse,
                              i4Availability: resolver.availability(for: pack))
        }
    }

    // MARK: - ⑤ 页面展示辅助（来源安装地址 / 设备身份预热）

    /// 某来源的**安装地址摘要**（供页面**只读展示**，不参与下载 —— 真正的下载地址由
    /// `cloudURL(for:source:)` 现解析）.
    ///
    /// · `.warehouse`：三个包的仓库 Release 直链同处一个目录，返回该目录（前缀）；
    ///   某个包的实际地址 = 前缀 + `pack.fileName`（如 `…/edge/217.ipa`）.
    /// · `.i4`：返回爱思云端**接口端点**；该来源的下载地址由**服务端按设备 UDID 现解析**，
    ///   无固定直链，故此处只给端点（页面另注明「按设备解析」）.
    ///
    /// 为什么只读、不做成可编辑：这两条地址都不是「用户改了就生效」的配置 ——
    /// 仓库直链是编译期常量（`Pack.cloudURL`），爱思地址由服务端按设备算；
    /// 做成可编辑却不被 `downloadCloudIPA` 消费，就是**假配置**（改了没用，反误导）.
    static func addressSummary(for source: CloudSource) -> String? {
        switch source {
        case .warehouse:
            guard let first = packs.first, !first.cloudURL.isEmpty else { return nil }
            guard let slash = first.cloudURL.lastIndex(of: "/") else { return first.cloudURL }
            return String(first.cloudURL[...slash])
        case .i4:
            return I4CloudResolverImpl.endpoint
        }
    }

    /// 预热本机设备身份（爱思云端可用性依赖 UDID）并**等到就绪**；返回是否已就绪.
    ///
    /// 为什么需要它：`I4CloudResolverImpl.availability` 是**同步零阻塞**的 —— 冷缓存时它只挂一次
    /// 后台预热就返回「读不到设备 UDID」；页面若只刷新一次，爱思云端会**一直灰着**（本页 bug 的根因）.
    /// 故页面在首屏后调本方法：等后台预热（建 RSD 隧道，秒级）完成，再刷新来源可用性.
    ///
    /// 为什么用**轮询进程内缓存**而不是直接 `LocalDeviceIdentity.load()`：后者会**再建一次隧道**，
    /// 与 `warmUpInBackground` 已挂的那次并发 ⇒ 白建一轮. 轮询只等那一次的结果.
    static func warmUpDeviceIdentityForI4() async -> Bool {
        if let snap = LocalDeviceIdentity.cachedSnapshot(), snap.isUsable { return true }
        LocalDeviceIdentity.warmUpInBackground()   // 幂等：已在跑则不重复建隧道
        for _ in 0..<50 {                          // 最多约 10s（0.2s × 50）
            if let snap = LocalDeviceIdentity.cachedSnapshot(), snap.isUsable { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    // MARK: - ② IPA 来源 · 云端下载（仓库云端 / 爱思云端）

    /// 按来源解析某包的云端下载地址.
    ///
    /// 仓库云端取 `pack.cloudURL`；爱思云端交注入的 `resolver`（**默认真实现**）.
    /// 不可用一律抛 `cloudSourceUnavailable`（含来源名与原因，**不静默跳过**）.
    static func cloudURL(for pack: Pack,
                         source: CloudSource,
                         resolver: I4CloudResolver = I4CloudResolverImpl()) async throws -> URL {
        switch source {
        case .warehouse:
            guard !pack.cloudURL.isEmpty, let url = URL(string: pack.cloudURL) else {
                throw I4MobileError.cloudSourceUnavailable(
                    pack: pack.fileName, source: CloudSource.warehouse.displayName,
                    reason: "未配置仓库 Release 直链.")
            }
            return url
        case .i4:
            return try await resolver.downloadURL(for: pack)
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
    ///   - source: 下载来源（`.warehouse` 仓库云端 / `.i4` 爱思云端）.
    ///   - resolver: 爱思云端解析器（仅 `.i4` 时用；**默认真实现** `I4CloudResolverImpl`）.
    /// - Throws: `cloudSourceUnavailable`（来源不可用）/ `cacheWriteFailed`（落盘失败）/ 底层下载错误.
    static func downloadCloudIPA(pack: Pack,
                                 from source: CloudSource = .warehouse,
                                 resolver: I4CloudResolver = I4CloudResolverImpl(),
                                 progress: (@Sendable (Double) -> Void)? = nil,
                                 onLog: (@Sendable (String) -> Void)? = nil) async throws {
        if isCached(pack) {
            onLog?("[i4移动端] \(pack.fileName) 已在缓存，跳过下载")
            return
        }
        let url = try await cloudURL(for: pack, source: source, resolver: resolver)
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

    /// 从指定来源下载所有**未缓存**的包（顺序 = `packs`）.
    ///
    /// 诚实边界：任一包失败即抛错，**不回滚**已下载的包（与 `installAll` 一致）.
    /// 调用方（UI）应先用 `packStatuses(resolver:)` 过滤出该来源**可用**的包，避免对不可用包空转报错.
    static func downloadAllMissingCloudIPAs(from source: CloudSource = .warehouse,
                                            resolver: I4CloudResolver = I4CloudResolverImpl(),
                                            progress: (@Sendable (Double) -> Void)? = nil,
                                            onLog: (@Sendable (String) -> Void)? = nil) async throws {
        let missing = packs.filter { !isCached($0) }
        for (idx, pack) in missing.enumerated() {
            onLog?("[i4移动端] (\(idx + 1)/\(missing.count)) 下载 \(pack.fileName)")
            try await downloadCloudIPA(pack: pack, from: source, resolver: resolver,
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
