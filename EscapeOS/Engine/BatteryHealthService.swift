import Foundation

/// v0.3.199：电池健康数据模型 —— diagnostics_relay IORegistry/IOPMPowerSource 解析结果。
/// 字段规则移植自 iDescriptor（github.com/iDescriptor/iDescriptor）utils.rs query_battery_info。
struct BatteryHealthInfo {
    var cycleCount: Int?
    var designCapacity: Int?      // mAh（出厂设计容量）
    var maxCapacity: Int?         // mAh（当前实际最大容量）
    var currentPercent: Int?      // 当前电量 %
    var healthPercent: Int?       // 健康度 % = max/design*100
    var serial: String?
    var isCharging: Bool?
    var fullyCharged: Bool?
    // v0.3.205：适配器（电源/电压）
    var adapterWatts: Int?        // W
    var adapterVoltage: Double?   // V（mV/1000）
    var adapterDescription: String?  // 连接描述（如 USB-C/无线）
    var batteryManufacturer: String? // 厂商（iOS 不暴露稳定字段，Apple 为推断）
    var raw: [String: Any] = [:]  // 调试用（字段缺失时可看）
}

/// v0.3.199：电池健康服务 —— diagnostics_relay IORegistry/IOPMPowerSource。
/// 非越狱、普通配对 + 解锁即可读取（iDescriptor 实证）。iOS 26/27 字段迁移已处理。
/// v0.3.205 修复：BatteryData.MaxCapacity 在某些设备返回 0-100 百分比而非 mAh
/// （iDescriptor issue #132/#133）→ 加 mAh 量级 sanity 过滤；电量改百分比；
/// 适配器电压/电源；厂商（Apple 推断）。
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
    /// v0.3.202：机型/系统版本从 lockdown GetValue 拿（IORegistry dict 无 ProductType）。
    static func fetchBatteryHealth() throws -> BatteryHealthInfo {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        let (productType, iosMajor) = try fetchLockdownInfo(adapter: adapter, handshake: handshake)
        var lastError: NSError?
        for attempt in 0..<3 {
            var client: OpaquePointer?
            if let e = diagnostics_relay_client_connect_rsd(adapter, handshake, &client) {
                lastError = ffiError(e, fallback: "连接诊断服务失败（需配对 + LocalDevVPN）")
            } else if let client {
                defer { diagnostics_relay_client_free(client) }
                return try query(client: client, productType: productType, iosMajor: iosMajor)
            } else {
                lastError = makeError("连接诊断服务失败")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? makeError("连接诊断服务失败")
    }

    /// lockdown GetValue（domain/key 均 nil → 全字典）取 ProductType / ProductVersion。
    private static func fetchLockdownInfo(adapter: OpaquePointer, handshake: OpaquePointer)
        -> (productType: String?, iosMajor: Int?) {
        var client: OpaquePointer?
        guard lockdownd_connect_rsd(adapter, handshake, &client) == nil, let client else {
            return (nil, nil)
        }
        defer { lockdownd_client_free(client) }
        var node: plist_t?
        if lockdownd_get_value(client, nil, nil, &node) != nil { return (nil, nil) }
        defer { if let node { plist_free(node) } }
        guard let node else { return (nil, nil) }
        var binPtr: UnsafeMutablePointer<CChar>?
        var binLen: UInt32 = 0
        guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS,
              let binPtr, binLen > 0 else { return (nil, nil) }
        defer { plist_mem_free(binPtr) }
        guard let dict = try? PropertyListSerialization.propertyList(
                from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil) as? [String: Any]
        else { return (nil, nil) }
        let productType = dict["ProductType"] as? String
        var major: Int? = nil
        if let ver = dict["ProductVersion"] as? String,
           let first = ver.split(separator: ".").first,
           let m = Int(first) {
            major = m
        }
        return (productType, major)
    }

    private static func query(client: OpaquePointer, productType: String?, iosMajor: Int?) throws -> BatteryHealthInfo {
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
        return parse(dict: dict, productType: productType, iosMajor: iosMajor)
    }

    /// 解析 IORegistry 电池字典（字段规则来自 iDescriptor utils.rs）。
    /// v0.3.205 修复 mAh/百分比混淆 + 电流百分比 + 适配器电压/电源。
    static func parse(dict: [String: Any], productType: String? = nil, iosMajor: Int? = nil) -> BatteryHealthInfo {
        func num(_ key: String, in d: [String: Any]) -> Int? {
            if let n = d[key] as? Int { return n }
            if let n = d[key] as? Double { return Int(n) }
            if let n = d[key] as? Bool { return n ? 1 : 0 }
            if let s = d[key] as? String { return Int(s) }
            return nil
        }
        func dbl(_ key: String, in d: [String: Any]) -> Double? {
            if let n = d[key] as? Double { return n }
            if let n = d[key] as? Int { return Double(n) }
            if let s = d[key] as? String { return Double(s) }
            return nil
        }
        let isIPhone = productType?.lowercased().hasPrefix("iphone") ?? false
        let bd = dict["BatteryData"] as? [String: Any] ?? [:]

        // 1. 循环次数：BatteryData 优先 → 顶层（iOS 27 beta 起移顶层）
        let cycle = num("CycleCount", in: bd) ?? num("CycleCount", in: dict)
        // 2. 设计容量：BatteryData.DesignCapacity（iDescriptor 无顶层回退，mAh）
        let design = num("DesignCapacity", in: bd) ?? num("DesignCapacity", in: dict)

        // 3. 最大容量 —— v0.3.207 修复「充电中虚高/随时变」：
        //    FullChargeCapacity = 当前满充估算，充电中会随电压电流浮动（iDescriptor 也踩，
        //    iOS26.6 健康度不准 issue #132）。**AppleRawMaxCapacity 才是稳定原始满充容量**，
        //    优先取它；FullChargeCapacity 仅兜底。仍保留 mAh sanity（>200 且 ≤ design+1000）。
        let isChargingNow = dict["IsCharging"] as? Bool ?? false
        let candidates: [(String, Int?)] = [
            ("AppleRawMaxCapacity", num("AppleRawMaxCapacity", in: dict)),
            ("BatteryData.FullChargeCapacity", num("FullChargeCapacity", in: bd)),
            ("FullChargeCapacity", num("FullChargeCapacity", in: dict)),
            ("BatteryData.MaxCapacity", num("MaxCapacity", in: bd)),
            ("top.MaxCapacity", num("MaxCapacity", in: dict)),
        ]
        var maxCapacity: Int? = nil
        for (src, val) in candidates {
            guard let val else { continue }
            if val >= 200 && (design == nil || val <= (design ?? 5000) + 1000) {
                maxCapacity = val
                break
            }
        }
        // 若全部落选（如 BatteryData.MaxCapacity 恰是百分比），兜底设计容量
        if maxCapacity == nil { maxCapacity = design }

        // 4. 健康度 —— v0.3.207：单调基线（物理真实健康度只会缓慢下降；充电估算上涨是噪声）。
        //    基线存 UserDefaults；允许下降立即更新；上涨仅当明显跳变（>2%，如换电池/校准）才采纳。
        var health: Int? = nil
        if let design, design > 0, let maxCapacity {
            let raw = min(100, max(0, Int((Double(maxCapacity) / Double(design)) * 100)))
            let cacheKey = "BatteryHealthBaselinePct"
            let baseline = UserDefaults.standard.integer(forKey: cacheKey)
            if baseline <= 0 {
                // 首次：记录基线
                UserDefaults.standard.set(raw, forKey: cacheKey)
                health = raw
            } else if raw <= baseline {
                // 下降或持平 → 更新基线
                UserDefaults.standard.set(raw, forKey: cacheKey)
                health = raw
            } else if raw > baseline {
                // 上涨：充电中视为噪声（保持基线）；非充电大涨视为换电池/校准（采纳）
                if !isChargingNow && raw - baseline > 2 {
                    UserDefaults.standard.set(raw, forKey: cacheKey)
                    health = raw
                } else {
                    health = baseline
                }
            }
        }

        // 5. 当前电量 —— v0.3.205 改百分比：
        //    iOS ≤26：AppleRawCurrentCapacity / AppleRawMaxCapacity × 100
        //    iOS >26：BatteryData.CurrentCapacity 已是百分比（clamp ≤100）
        var currentPercent: Int? = nil
        if let iosMajor, iosMajor > 26 {
            if let c = num("CurrentCapacity", in: bd) {
                currentPercent = min(100, c)
            } else if let cur = num("AppleRawCurrentCapacity", in: dict),
                      let max = num("AppleRawMaxCapacity", in: dict), max > 0 {
                currentPercent = min(100, Int(Double(cur) / Double(max) * 100))
            }
        } else {
            if let cur = num("AppleRawCurrentCapacity", in: dict),
               let max = num("AppleRawMaxCapacity", in: dict), max > 0 {
                currentPercent = min(100, Int(Double(cur) / Double(max) * 100))
            } else if let c = num("CurrentCapacity", in: bd) {
                currentPercent = min(100, c)
            }
        }

        let serial = dict["Serial"] as? String
        let isCharging: Bool? = dict["IsCharging"] as? Bool
            ?? ((dict["ChargerData"] as? [String: Any])?["IsCharging"] as? Bool)
        let fullyCharged = dict["FullyCharged"] as? Bool

        // 6. 适配器（v0.3.205）
        var adapterWatts: Int? = nil
        var adapterVoltage: Double? = nil
        var adapterDescription: String? = nil
        if let details = dict["AppleRawAdapterDetails"] as? [Any],
           let first = details.first as? [String: Any] {
            // 新机型：AdapterVoltage(mV) / Watts(W)
            if let mv = dbl("AdapterVoltage", in: first), mv > 0 {
                adapterVoltage = mv / 1000.0
            }
            adapterWatts = num("Watts", in: first) ?? num("AdapterWatts", in: first)
        } else if let adapter = dict["AdapterDetails"] as? [String: Any] {
            adapterWatts = num("Watts", in: adapter)
            if let mv = dbl("AdapterVoltage", in: adapter), mv > 0 {
                adapterVoltage = mv / 1000.0
            }
            adapterDescription = adapter["Description"] as? String
        }
        // 7. 厂商：iOS 不暴露稳定字段（IOPMPowerSource 规范含但 iOS10+ 裁剪）。
        //    Apple 设备电池实际为 Apple 认证（推断显示 Apple），原始键尝试读取。
        let manufacturer = (dict["Manufacturer"] as? String)
            ?? (dict["BatteryManufacturer"] as? String)
            ?? "Apple"

        return BatteryHealthInfo(
            cycleCount: cycle,
            designCapacity: design,
            maxCapacity: maxCapacity,
            currentPercent: currentPercent,
            healthPercent: health,
            serial: serial,
            isCharging: isCharging,
            fullyCharged: fullyCharged,
            adapterWatts: adapterWatts,
            adapterVoltage: adapterVoltage,
            adapterDescription: adapterDescription,
            batteryManufacturer: manufacturer,
            raw: dict
        )
    }
}
