import Foundation

/// Airlift（AirTraffic 沙盒逃逸）支持的系统范围（移植自 AirBeep 的 `SystemCompatibility`）.
///
/// 范围依据 airlift 的 AirTraffic 逃逸：iOS/iPadOS 18.0 至 27.2 B2。
/// 超出范围**如实报不支持**（由访问层在运行时给出真实错误），不做乐观假设.
///
/// 命名说明：AirBeep 原类名 `SystemCompatibility`（过于通用，易与其它兼容性判据撞名）；
/// 本仓放在 `Airlift/` 目录下并加 `Airlift` 前缀，**判据逐字一致**.
enum AirliftSystemCompatibility {
    static var isSupported: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 18 else { return false }
        if version.majorVersion > 27 { return false }
        if version.majorVersion == 27 {
            if version.minorVersion > 2 { return false }
            if version.minorVersion == 2, version.patchVersion > 0 { return false }
        }
        return true
    }

    static var supportedRangeDescription: String {
        "iOS/iPadOS 18.0–27.2 B2"
    }
}
