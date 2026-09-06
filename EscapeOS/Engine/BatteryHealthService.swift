import Foundation

/// v0.3.199：电池健康数据模型 —— diagnostics_relay IORegistry/IOPMPowerSource 解析结果。
/// 字段规则移植自 iDescriptor（github.com/iDescriptor/iDescriptor）utils.rs query_battery_info。
struct BatteryHealthInfo {
    var cycleCount: Int?
    var designCapacity: Int?      // mAh
    var maxCapacity: Int?         // mAh（当前实际最大容量）
    var currentCapacity: Int?     // mAh（当前剩余）
    var healthPercent: Int?       // 健康度 % = max/design*100
    var serial: String?
    var isCharging: Bool?
    var fullyCharged: Bool?
    var adapterWatts: Int?
    var raw: [String: Any] = [:]  // 调试用（字段缺失时可看）
}

/// v0.3.199：电池健康服务 —— diagnostics_relay IORegistry/IOPMPowerSource。
/// 非越狱、普通配对 + 解锁即可读取（iDescriptor 实证）。iOS 26/27 字段迁移已处理。
enum BatteryHealthService {
    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "BatteryHealth", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func ffiError(_ e: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let e else { return makeError(fallback) }
        defer { idevice_error_free(e) }
        let msg = e.pointee.message.map { String(cString: $0) } ?? ""
        return NSError(domain: "BatteryHealth", code: Int(e.pointee.code),
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
    /// 建隧道（3 次退避重试，参照 RSD 铁律）
    private static func createTunnel() throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件。请先在「应用管理」导入配对文件（需 LocalDevVPN + 开发者模式）。")
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
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let e = "EscapeSpaceBattery".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn,
                            pairingFile,
                            nil,
                            nil,
                            &tunnel.adapter,
                            &tunnel.handshake
                        )
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

    /// 读取电池健康（同步阻塞——调用方需放后台线程）。
    static func fetchBatteryHealth() throws -> BatteryHealthInfo {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var lastError: NSError?
        for attempt in 0..<3 {
            var client: OpaquePointer?
            if let e = diagnostics_relay_client_connect_rsd(adapter, handshake, &client) {
                lastError = ffiError(e, fallback: "连接诊断服务失败（需配对 + LocalDevVPN）")
            } else if let client {
                defer { diagnostics_relay_client_free(client) }
                return try query(client: client)
            } else {
                lastError = makeError("连接诊断服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接诊断服务失败")
    }

    private static func query(client: OpaquePointer) throws -> BatteryHealthInfo {
        var node: plist_t?
        if let e = diagnostics_relay_client_ioregistry(client, nil, nil, "IOPMPowerSource", &node) {
            throw ffiError(e, fallback: "查询电池 IORegistry 失败")
        }
        defer { if let node { plist_free(node) } }
        guard let node else {
            throw makeError("未返回电池数据（设备可能未解锁，或 iOS 版本不支持）")
        }
        var binPtr: UnsafeMutablePointer<CChar>?
        var binLen: UInt32 = 0
        guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS,
              let binPtr, binLen > 0 else {
            throw makeError("电池 plist 序列化失败")
        }
        defer { plist_mem_free(binPtr) }
        let data = Data(bytes: binPtr, count: Int(binLen))
        guard let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any] else {
            throw makeError("电池 plist 解析失败")
        }
        return parse(dict: dict)
    }

    /// 解析 IORegistry 电池字典（字段规则来自 iDescriptor utils.rs，含 iOS 26/27 迁移）。
    static func parse(dict: [String: Any]) -> BatteryHealthInfo {
        func int(_ key: String, in d: [String: Any]) -> Int? {
            if let n = d[key] as? Int { return n }
            if let n = d[key] as? Double { return Int(n) }
            if let s = d[key] as? String { return Int(s) }
            return nil
        }
        let bd = dict["BatteryData"] as? [String: Any] ?? [:]
        let cycle = int("CycleCount", in: bd) ?? int("CycleCount", in: dict)
        let design = int("DesignCapacity", in: bd) ?? int("DesignCapacity", in: dict)
        let maxBatteryData = int("MaxCapacity", in: bd)
        let maxTopRaw = int("AppleRawMaxCapacity", in: dict) ?? int("FullChargeCapacity", in: dict)
        let prefersTopRaw = isIPhoneNewerThan8_1(model: dict["ProductType"] as? String)
        let maxCapacity: Int? = {
            if prefersTopRaw { return maxTopRaw }
            return maxTopRaw ?? maxBatteryData
        }()
        let currentCapacity = int("CurrentCapacity", in: bd) ?? int("AppleRawCurrentCapacity", in: dict)
        var health: Int? = nil
        if let design, design > 0, let maxCapacity {
            health = min(100, Int((Double(maxCapacity) / Double(design)) * 100))
        }
        let serial = dict["Serial"] as? String
        let isCharging = dict["IsCharging"] as? Bool
        let fullyCharged = dict["FullyCharged"] as? Bool
        var adapterWatts: Int? = nil
        if let adapter = dict["AdapterDetails"] as? [String: Any],
           let watts = int("Watts", in: adapter) { adapterWatts = watts }
        return BatteryHealthInfo(
            cycleCount: cycle,
            designCapacity: design,
            maxCapacity: maxCapacity,
            currentCapacity: currentCapacity,
            healthPercent: health,
            serial: serial,
            isCharging: isCharging,
            fullyCharged: fullyCharged,
            adapterWatts: adapterWatts,
            raw: dict
        )
    }

    /// iPhone 且比 iPhone8,1（6s）新 → true（顶层 AppleRawMaxCapacity 优先）。
    static func isIPhoneNewerThan8_1(model: String?) -> Bool {
        guard let model else { return false }
        let m = model.lowercased()
        guard m.hasPrefix("iphone") else { return false }
        let comps = m.dropFirst("iphone".count).split(separator: ",")
        if comps.count == 2,
           let major = Int(comps[0]), let minor = Int(comps[1]) {
            if major > 8 { return true }
            if major == 8 { return minor > 1 }
            return false
        }
        return true
    }
}
