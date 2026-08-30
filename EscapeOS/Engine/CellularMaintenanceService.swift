import Foundation
import Darwin

/// 蜂窝网络维护服务（v0.2.138，参考 CellularInfo 的 `CoreTelephonyController`）。
///
/// 「刷新蜂窝网络信号」= 进程内调 CoreTelephony 私有 C API
/// `_CTServerConnectionCreate` + `_CTServerConnectionResetModem`。
///
/// ⚠️ 权限说明（与 CellularInfo 一致）：`_CTServerConnectionResetModem`
/// 需要 `com.apple.CommCenter.fine-grained` / `spi` entitlement 才会被
/// CommCenter 真正受理；无权限时请求**静默丢弃、不报错**。EscapeSpace
/// 当前只有 `get-task-allow`，所以本功能大概率无效 —— 保留它作为
/// 「零成本尝试」，真正可靠的是「重启蜂窝网络服务」（RSD 隧道杀
/// CommCenter，见 `DeviceControlService.restartCommCenter`，无需 root）。
final class CellularMaintenanceService {

    static let shared = CellularMaintenanceService()
    private init() {}

    private let coreTelephonyHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_NOW)
    }()

    private typealias CTServerConnectionCreateFn =
        @convention(c) (CFAllocator?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> OpaquePointer?
    private typealias CTServerConnectionResetModemFn =
        @convention(c) (OpaquePointer?, CFString?) -> Void

    private var createConnection: CTServerConnectionCreateFn? {
        guard let handle = coreTelephonyHandle,
              let sym = dlsym(handle, "_CTServerConnectionCreate") else { return nil }
        return unsafeBitCast(sym, to: CTServerConnectionCreateFn.self)
    }

    private var resetModem: CTServerConnectionResetModemFn? {
        guard let handle = coreTelephonyHandle,
              let sym = dlsym(handle, "_CTServerConnectionResetModem") else { return nil }
        return unsafeBitCast(sym, to: CTServerConnectionResetModemFn.self)
    }

    /// 发送「重置调制解调器」请求（刷新蜂窝网络信号）。
    /// 返回 true 仅代表请求已发出；是否被受理取决于进程是否具备
    /// `com.apple.CommCenter.fine-grained: spi` entitlement。
    func sendResetModemRequest() -> Bool {
        guard let create = createConnection, let reset = resetModem else { return false }
        guard let connection = create(kCFAllocatorDefault, nil, nil) else { return false }
        reset(connection, "UserTriggeredReload" as CFString)
        return true
    }
}
