//
//  Configuration.swift
//  IPATool
//
//  Created by QAQ on 2023/10/4.
//

import Foundation

// ─── SAP（Store Activation Protocol）签名注入点（v0.3.1）────────────────────────
//
// Apple 2026 年起要求 App Store 认证请求携带 `X-Apple-ActionSignature` 头
// （ipatool PR #525 实证：无此头 → 账号校验前直接 403，无论账号真假）。
// 签名算法在 Apple 私有 CommerceKit 的 x86-64 代码里，Swift 层无法直接实现——
// 由宿主 app（EscapeSpace）注入签名器工厂：Unicorn 解释执行 CommerceKit
// 产出签名（见 sapbridge/ 与 EscapeOS/Services/AppleAuth/SapSigner.swift）。
// vendor 层只依赖这里的抽象，不 import 任何宿主类型。

/// SAP 端点三元组（来自 bag.xml 的 `sign-sap-setup` / `sign-sap-setup-cert` /
/// `sign-sap-version` 键，ipatool appstore_bag.go 同款）。
public struct SAPConfig {
    public var setupURL: URL
    public var certificateURL: URL
    public var version: UInt32
    /// SAP 硬件标识原始字节（1–20 字节）。约定取 deviceIdentifier（大写 hex MAC）
    /// 的原始字节，与请求体里的 guid 保持同一机器身份（对齐 ipatool machine_id.go）。
    public var hardwareID: Data

    public init(setupURL: URL, certificateURL: URL, version: UInt32, hardwareID: Data) {
        self.setupURL = setupURL
        self.certificateURL = certificateURL
        self.version = version
        self.hardwareID = hardwareID
    }
}

/// SAP 签名器抽象。`sign(requestBody:)` 对**最终发出的请求体字节**签名并返回
/// base64（作为 `X-Apple-ActionSignature` 头值）；`close()` 释放模拟器（可重复调用）。
public protocol SAPActionSigning: AnyObject {
    func sign(requestBody: Data) throws -> String
    func close()
}

public enum Configuration {
    /*
     DeviceIdentifier is a unique identifier for your device.

     - On macOS, it is a MAC address and can be read by calling DeviceIdentifier.system.
     - If that fails and throws an error, use DeviceIdentifier.random and **save it**

     **It is a must set value before any network request**
     **otherwise your account may be locked for security reason**
     */
    // iOS 上原版会拿到 ""（DeviceIdentifier.system() 永远 throw），而下面的
    // tlsConfiguration 有一条 `precondition(!deviceIdentifier.isEmpty)` ——
    // 不设置就一调用即崩溃。这里兜底成随机值；真正的持久化值由
    // AppStoreDownloadStore 启动时写入（见 bootstrapDeviceIdentifier()），
    // 避免每次冷启动都换一台"机器"触发 Apple 风控。
    public nonisolated(unsafe) static var deviceIdentifier: String = (try? DeviceIdentifier.system()) ?? DeviceIdentifier.random() {
        didSet {
            assert(!deviceIdentifier.contains(":"))
            assert(!deviceIdentifier.contains("-"))
            assert(!deviceIdentifier.contains(" "))
            assert(!deviceIdentifier.contains("\n"))
        }
    }

    // v0.3.175：UA 切回 Configurator——ipatool PR#486/#525 实证（26HOTFIX24 后，
    // 2026-08 认证已迁移）：Configurator/2.17 是 ipatool 默认 UA，登录 + 2FA 验证码
    // 收发 + 购买全链路验证通过（commerce-grade token）；v0.2.151/158 时代 iTunes UA
    // 的"200 实测"发生在认证迁移之前，结论已过期。iTunes Mac UA 形态易触发 Apple
    // 对第三方客户端的风控（验证码发送走短信而非受信任设备推送，中国运营商拦截
    // 美区短号短信 → 收不到码，用户真机实锤）。
    public nonisolated(unsafe) static let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    // v0.4.1：bag.xml 专用 UA（= upstream ipatool pkg/http DefaultUserAgent）。
    // 实测 2026-08-31：bag.xml 只对 Configurator UA 返回 authenticateAccount 与
    // sign-sap-* 完整键（iTunes UA / 无 UA 均缺失）——认证请求的 UA 不受影响，
    // 仍是上面的 iTunes UA。
    public nonisolated(unsafe) static var bagUserAgent: String = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    // ─── SAP（Store Activation Protocol）签名注入点（v0.3.1）────────────────────────
    //
    // Apple 2026 年起要求 App Store 认证请求携带 `X-Apple-ActionSignature` 头
    // （ipatool PR #525 实证：无此头 → 账号校验前直接 403，无论账号真假）。
    // 签名算法在 Apple 私有 CommerceKit 的 x86-64 代码里，Swift 层无法直接实现——
    // 由宿主 app（EscapeSpace）注入签名器工厂：Unicorn 解释执行 CommerceKit
    // 产出签名（见 sapbridge/ 与 EscapeOS/Services/AppleAuth/SapSigner.swift）。
    // vendor 层只依赖这里的抽象，不 import 任何宿主类型。
    //
    // 注意：SAPConfig / SAPActionSigning 是**文件顶层类型**（在枚举外声明）——
    // 曾误作 Configuration 嵌套类型导致全项目 "cannot find type in scope"
    // （v0.3.1 首轮 CI 实锤）。

    /// JIT 未启用（Unicorn TCG 需要 JIT，无 entitlement 进程写可执行内存会崩）。
    /// Authenticate 捕获后**直接中止登录**并原样抛给 UI——不回退未签名请求
    ///（Apple 必拒，回退只会用一条误导性的 403 掩盖真正原因）。
    public struct SAPJITUnavailableError: LocalizedError {
        public var errorDescription: String? {
            "JIT 未启用：请先用 StikDebug 为 LiveContainer 开启 JIT，再回来登录"
        }
        public init() {}
    }

    /// 宿主注入的签名器工厂（app 启动时设置一次后只读）。v0.3.11 改 async：
    /// 远程签名（局域网 PC 服务）的初始化是网络操作。nil / 抛错 → 认证请求
    /// 退回未签名行为（会被 Apple 403，保留可诊断的错误路径）。
    public nonisolated(unsafe) static var sapSignerFactory: ((SAPConfig) async throws -> SAPActionSigning)?

    public nonisolated(unsafe) static var tlsConfiguration: TLSConfiguration = {
        precondition(!deviceIdentifier.isEmpty, "deviceIdentifier must be set")
        #if DEBUG
            var conf = TLSConfiguration.makeClientConfiguration()
            conf.certificateVerification = .none
            return conf
        #else
            return TLSConfiguration.makeClientConfiguration()
        #endif
    }()

    public static let storeFrontValues: [String: String] = kCountryCodes
    public static let timeoutConnect: Int64 = 10
    public static let timeoutRead: Int64 = 30

    /// 构造一个配置好的 HTTPClient。ApplePackage 全套上下游（Bag/Authenticator/Download
    /// /VersionFinder/VersionLookup）共享同一构造入口，避免在调用点堆叠链式 .then{}。
    /// 1.2.7 主线同款 (`Configuration.makeHTTPClient(redirectConfiguration:)`)，shim 环境
    /// 里直接调 shim 的 HTTPClient 构造器。
    public static func makeHTTPClient(
        redirectConfiguration: RedirectConfiguration
    ) -> HTTPClient {
        HTTPClient(
            configuration: .init(
                tlsConfiguration: tlsConfiguration,
                redirectConfiguration: redirectConfiguration,
                timeout: .init(
                    connect: .seconds(timeoutConnect),
                    read: .seconds(timeoutRead)
                )
            )
        )
    }

    #if os(macOS)
        public nonisolated(unsafe) static var homePath: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ipatool", isDirectory: true)
        { didSet { assert(homePath.isFileURL) } }
    #else
        public nonisolated(unsafe) static var homePath: URL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(".ipatool", isDirectory: true)
        { didSet { assert(homePath.isFileURL) } }
    #endif

    public static func storeId(for countryCode: String) -> String? {
        storeFrontValues[countryCode]
    }

    /// v0.3.171：账号区域（决定 X-Apple-Store-Front）——须与 Apple ID 注册地区一致，
    /// 由宿主（AppStore 下载页设置）登录前注入，默认 US（ipatool 同款，兼容性最好）.
    public nonisolated(unsafe) static var countryCode: String = "US"

    public static func countryCode(for storeId: String) -> String? {
        storeFrontValues.first(where: { $0.value == storeId })?.key
    }

    public static func accountPath(for email: String) -> URL {
        let emailLower = email.lowercased()
        let hash = emailLower.md5
        let accountDir = homePath.appendingPathComponent(hash)
        try? FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        return accountDir.appendingPathComponent("account.json")
    }

    public static func saveLoginAccount(_ account: AppStoreAccount, for email: String) {
        let fileURL = accountPath(for: email)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try! encoder.encode(account)
        try! data.write(to: fileURL)
    }

    public static func withAccount<T>(email: String, _ body: (inout AppStoreAccount) async throws -> T) async throws -> T {
        var account: AppStoreAccount = try {
            let fileURL = accountPath(for: email)
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(AppStoreAccount.self, from: data)
        }()
        defer { saveLoginAccount(account, for: email) }
        return try await body(&account)
    }
}

private let kCountryCodes = [
    "AE": "143481",
    "AG": "143540",
    "AI": "143538",
    "AL": "143575",
    "AM": "143524",
    "AO": "143564",
    "AR": "143505",
    "AT": "143445",
    "AU": "143460",
    "AZ": "143568",
    "BB": "143541",
    "BD": "143490",
    "BE": "143446",
    "BG": "143526",
    "BH": "143559",
    "BM": "143542",
    "BN": "143560",
    "BO": "143556",
    "BR": "143503",
    "BS": "143539",
    "BW": "143525",
    "BY": "143565",
    "BZ": "143555",
    "CA": "143455",
    "CH": "143459",
    "CI": "143527",
    "CL": "143483",
    "CN": "143465",
    "CO": "143501",
    "CR": "143495",
    "CY": "143557",
    "CZ": "143489",
    "DE": "143443",
    "DK": "143458",
    "DM": "143545",
    "DO": "143508",
    "DZ": "143563",
    "EC": "143509",
    "EE": "143518",
    "EG": "143516",
    "ES": "143454",
    "FI": "143447",
    "FR": "143442",
    "GB": "143444",
    "GD": "143546",
    "GE": "143615",
    "GH": "143573",
    "GR": "143448",
    "GT": "143504",
    "GY": "143553",
    "HK": "143463",
    "HN": "143510",
    "HR": "143494",
    "HU": "143482",
    "ID": "143476",
    "IE": "143449",
    "IL": "143491",
    "IN": "143467",
    "IS": "143558",
    "IT": "143450",
    "IQ": "143617",
    "JM": "143511",
    "JO": "143528",
    "JP": "143462",
    "KE": "143529",
    "KN": "143548",
    "KR": "143466",
    "KW": "143493",
    "KY": "143544",
    "KZ": "143517",
    "LB": "143497",
    "LC": "143549",
    "LI": "143522",
    "LK": "143486",
    "LT": "143520",
    "LU": "143451",
    "LV": "143519",
    "MD": "143523",
    "MG": "143531",
    "MK": "143530",
    "ML": "143532",
    "MN": "143592",
    "MO": "143515",
    "MS": "143547",
    "MT": "143521",
    "MU": "143533",
    "MV": "143488",
    "MX": "143468",
    "MY": "143473",
    "NE": "143534",
    "NG": "143561",
    "NI": "143512",
    "NL": "143452",
    "NO": "143457",
    "NP": "143484",
    "NZ": "143461",
    "OM": "143562",
    "PA": "143485",
    "PE": "143507",
    "PH": "143474",
    "PK": "143477",
    "PL": "143478",
    "PT": "143453",
    "PY": "143513",
    "QA": "143498",
    "RO": "143487",
    "RS": "143500",
    "RU": "143469",
    "SA": "143479",
    "SE": "143456",
    "SG": "143464",
    "SI": "143499",
    "SK": "143496",
    "SN": "143535",
    "SR": "143554",
    "SV": "143506",
    "TC": "143552",
    "TH": "143475",
    "TN": "143536",
    "TR": "143480",
    "TT": "143551",
    "TW": "143470",
    "TZ": "143572",
    "UA": "143492",
    "UG": "143537",
    "US": "143441",
    "UY": "143514",
    "UZ": "143566",
    "VC": "143550",
    "VE": "143502",
    "VG": "143543",
    "VN": "143471",
    "YE": "143571",
    "ZA": "143472",
]
