import Foundation

/// v0.3.305：设备信息补全 —— 爱思「设备详情」缺项的**实测可用通道**。
///
/// ## 为什么需要它
/// 真机 iPhone15,4 / iOS 27.0（2026-09-11 USB 直连实测）：
/// `com.apple.mobile.iTunes` 域只剩 74 个键，**零部件序列号 / 容量 / 循环次数 / DeviceSupports\*
/// 全部不在其中**（这些是老 iOS 才有的键）。此前设备信息里大片「—」的根因就在这里。
///
/// ## 实测可用的通道
/// `diagnostics_relay` 的 IORegistry **按节点名**查询（`EntryName`），一次隧道可查多个节点：
///
/// | 节点 | 取到的项 |
/// |---|---|
/// | `product`（IODeviceTree） | `coverglass-serial-number`（盖板码）、`raw-panel-serial-number`（屏幕序列号）、
/// | | `ambient-light-sensor-serial-num`（环境光）、`backglass-compass-serial-number`、
/// | | `unique-model`、`wifi-chipset`、`baseband-chipset`、`product-description` |
/// | `smc-charger` | `battery-id`（电池型号，如 `741-01369`） |
/// | `AppleSmartBattery` | `Serial`（电池序列号）、`Voltage`、`InstantAmperage`、`AtCriticalLevel`、
/// | | `DeadBatteryBootData.GeneralPayload.AverageBattSkinTemp`（电池表皮温度，℃） |
/// | `AppleEmbeddedNVMeController` | `Controller Characteristics.default-bits-per-cell`（硬盘类型） |
///
/// ## 实测**取不到**的项（爱思能显示是因为走它自己的服务端，不是从设备读）
/// `LatticeSerialNumber`（点阵）、`InfraredCameraSerialNumber`（红外摄像头）、`Vibration`（震动器编码）、
/// 电池 `Temperature` / `AtWarnLevel` / `DateOfFirstUse` ——
/// 设备树 `sacm-jasper` / `pearl-sep` / `haptics` / `prox` / `als` 节点里都没有序列号属性。
struct DeviceEnrichInfo {
    // 设备树 /product
    var coverglassSerial: String?      // 盖板码
    var panelSerial: String?           // 屏幕序列号
    var ambientLightSerial: String?    // 环境光序列号
    var backglassCompassSerial: String?
    var uniqueModel: String?           // 硬件型号（如 D37AP）
    var wifiChipset: String?           // Wi-Fi 芯片（如 4387）
    var basebandChipset: String?       // 基带芯片（如 mav23）
    var productDescription: String?    // 机型描述（如 iPhone 15）
    // 电池
    var batterySerial: String?         // 电池序列号（AppleSmartBattery.Serial）
    var batteryModelID: String?        // 电池型号（smc-charger.battery-id）
    var batteryVoltageMV: Int?         // 当前电压 mV
    var batteryAmperageMA: Int?        // 电池电流 mA（负=放电）
    var batterySkinTempC: Int?         // 电池表皮温度 ℃（上次欠压启动记录）
    var batteryCycleCount: Int?        // 循环次数（AppleSmartBattery.CycleCount；iOS 27 的 iTunes 域已无此键）
    var atCriticalLevel: Bool?         // 电池处于临界水平
    // 存储
    var diskCellType: String?          // 硬盘类型 SLC/MLC/TLC/QLC
    // 原始
    var rawProduct: [String: Any] = [:]
    var rawBattery: [String: Any] = [:]
}

enum DeviceEnrichService {

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "DeviceEnrich", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func ffiError(_ e: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let e else { return makeError(fallback) }
        defer { idevice_error_free(e) }
        let msg = e.pointee.message.map { String(cString: $0) } ?? ""
        return NSError(domain: "DeviceEnrich", code: Int(e.pointee.code),
                       userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? fallback : msg])
    }

    private static var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    /// 建隧道（3 次退避重试，遵循 RSD 铁律：一次业务操作只建一条隧道）
    private static func createTunnel() throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件，请先导入配对文件（需 LocalDevVPN + 开发者模式）")
        }
        var pairingFile: OpaquePointer?
        if let e = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw ffiError(e, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let e = "EscapeSpaceEnrich".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                                                hn, pairingFile, nil, nil,
                                                &tunnel.adapter, &tunnel.handshake)
                    }
                }
            }
            if let e {
                lastError = ffiError(e, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = makeError("创建开发者隧道失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("创建开发者隧道失败")
    }

    /// 采集补全信息（同步阻塞——调用方放后台线程）.
    /// 单个节点查不到不影响其它节点：全部 best-effort，失败即留空.
    static func fetch() throws -> DeviceEnrichInfo {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var client: OpaquePointer?
        if let e = diagnostics_relay_client_connect_rsd(adapter, handshake, &client) {
            throw ffiError(e, fallback: "连接诊断服务失败（需配对 + LocalDevVPN）")
        }
        guard let client else { throw makeError("连接诊断服务失败") }
        defer { diagnostics_relay_client_free(client) }

        var info = DeviceEnrichInfo()
        if let product = ioregistry(client: client, entryName: "product") {
            info.rawProduct = product
            info.coverglassSerial = text(product["coverglass-serial-number"])
            info.panelSerial = text(product["raw-panel-serial-number"])
            info.ambientLightSerial = text(product["ambient-light-sensor-serial-num"])
            info.backglassCompassSerial = text(product["backglass-compass-serial-number"])
            info.uniqueModel = text(product["unique-model"])
            info.wifiChipset = text(product["wifi-chipset"])
            info.basebandChipset = text(product["baseband-chipset"])
            info.productDescription = text(product["product-description"])
        }
        if let charger = ioregistry(client: client, entryName: "smc-charger") {
            info.batteryModelID = text(charger["battery-id"])
        }
        if let battery = ioregistry(client: client, entryName: "AppleSmartBattery") {
            info.rawBattery = battery
            info.batterySerial = text(battery["Serial"])
            info.batteryVoltageMV = int(battery["Voltage"])
            info.batteryCycleCount = int(battery["CycleCount"])
            info.batteryAmperageMA = int(battery["InstantAmperage"]).map { $0 > 32768 ? $0 - 65536 : $0 }
            info.atCriticalLevel = bool(battery["AtCriticalLevel"])
            let dead = battery["DeadBatteryBootData"] as? [String: Any]
            let payload = dead?["GeneralPayload"] as? [String: Any]
            info.batterySkinTempC = int(payload?["AverageBattSkinTemp"])
        }
        if let storage = StorageDetailService.queryNode(client: client,
                                                       entryClass: "AppleEmbeddedNVMeController") {
            info.diskCellType = StorageDetailService.parse(storage).cellType
        }
        return info
    }

    // MARK: - IORegistry 查询

    /// 按 `EntryName` 查一个 IORegistry 节点 → 字典（查不到返回 nil）
    private static func ioregistry(client: OpaquePointer, entryName: String) -> [String: Any]? {
        var node: plist_t?
        let rc = entryName.withCString { nameCStr in
            diagnostics_relay_client_ioregistry(client, nil, nameCStr, nil, &node)
        }
        if rc != nil {
            if let rc { idevice_error_free(rc) }
            return nil
        }
        guard let node else { return nil }
        defer { plist_free(node) }
        var binPtr: UnsafeMutablePointer<CChar>?
        var binLen: UInt32 = 0
        guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS, let binPtr, binLen > 0 else {
            return nil
        }
        defer { plist_mem_free(binPtr) }
        return (try? PropertyListSerialization.propertyList(
            from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil)) as? [String: Any]
    }

    /// 取值 → 可读字符串.
    ///
    /// 设备树节点的值大多是**裸字节（binary plist 的 Data）**：C 字符串以 NUL 结尾，
    /// 例如 `CoverglassSerialNumber` = `GLDH620026S0000083+9000…\0`；
    /// 少数是 4/8 字节小端整数（`unique-model` 是字符串，`wifi-chipset` 是字符串）。
    static func text(_ v: Any?) -> String? {
        switch v {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case let d as Data:
            let bytes = [UInt8](d)
            let cut = bytes.prefix { $0 != 0 }
            guard !cut.isEmpty else { return nil }
            // 只接受可打印 ASCII（否则视为二进制字段，不展示）
            guard cut.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
            let s = String(decoding: cut, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }

    /// 整数取值（兼容 Data 小端编码）
    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let d as Data:
            switch d.count {
            case 1: return Int(d[0])
            case 2: return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
            case 4: return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            case 8: return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
            default: return nil
            }
        case let s as String: return Int(s)
        default: return nil
        }
    }

    /// 布尔取值（兼容 1/0 与 Data）
    static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let i = int(v) { return i != 0 }
        return nil
    }
}
