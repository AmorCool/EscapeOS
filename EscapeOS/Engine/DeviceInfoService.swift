import Foundation
import UIKit

/// v0.3.208：设备信息（照搬 iDescriptor 完整字段清单）.
/// 数据源：lockdown 整棵字典（一次 GetValue）+ com.apple.disk_usage 域 +
/// AFC device_info + DiagnosticsRelay mobilegestalt + sysctl 本机.
struct DeviceInfoModel {
    // 顶部/基础
    var modelName: String          // Marketing 机型名
    var productType: String        // hw.machine: "iPhone13,1"
    var hardwareModel: String?     // lockdown HardwareModel: "D52gAP"
    var modelNumber: String?       // lockdown ModelNumber: "MGA82LL/A"
    var deviceClass: String?       // lockdown DeviceClass: "iPhone"
    var activationState: String?   // lockdown ActivationState: "Activated"
    var region: String?            // lockdown RegionInfo 解析
    var hardwarePlatform: String?  // lockdown HardwarePlatform: "t8120"
    var cpuArchitecture: String?    // lockdown CPUArchitecture: "arm64e"
    var firmwareVersion: String?   // lockdown FirmwareVersion: "iBoot-..."
    var buildVersion: String?      // lockdown BuildVersion: "21G93"
    var systemVersion: String      // iOS 26.x
    var productionDevice: String?  // ProductionSOC bool → "是/否"
    var jailbroken: Bool?           // afc /bin 是否非空
    var deviceName: String?         // lockdown DeviceName
    var deviceColor: String?         // lockdown DeviceColor
    var wiFiAddress: String?         // lockdown WiFiAddress
    var ethernetAddress: String?     // lockdown EthernetAddress
    var bluetoothAddress: String?    // lockdown BluetoothAddress
    // 序列号/隐私敏感（v0.3.208：统一小眼睛+长按复制）
    var serialNumber: String?        // lockdown SerialNumber
    var imei: String?                // lockdown InternationalMobileEquipmentIdentity
    var imei2: String?               // lockdown InternationalMobileEquipmentIdentity2
    var imsi: String?                // lockdown InternationalMobileSubscriberIdentity
    var imsi2: String?               // lockdown InternationalMobileSubscriberIdentity2
    var udid: String?                // lockdown UniqueDeviceID
    var meid: String?                // lockdown MobileEquipmentIdentifier
    var ecid: String?                // DiagnosticsRelay mobilegestalt UniqueChipID
    var mlbSerial: String?           // DiagnosticsRelay mobilegestalt MLBSerialNumber
    var basebandSerial: String?      // DiagnosticsRelay mobilegestalt BasebandSerialNumber
    // 存储
    var totalDiskBytes: Int64?       // lockdown com.apple.disk_usage TotalDataCapacity
    var totalDataBytes: Int64?
    var totalSystemBytes: Int64?
    var storageTotalGB: Int
    var storageFreeGB: Int
    // CPU/内存
    var cpuCount: Int
    var memoryMB: Int
    // v0.3.285：移植爱思设备信息面板字段（逆向 i4Tools idm_info.dll 的 255 项键名清单）
    // 电池（com.apple.mobile.iTunes + com.apple.mobile.battery 域）
    var designCapacity: Int?            // DesignCapacity（mAh）
    var maxCapacity: Int?               // AppleRawMaxCapacity -> MaxCapacity（实际容量）
    var batteryHealthPercent: Int?      // maxCapacity / designCapacity
    var cycleCount: Int?                // CycleCount
    var batteryLevel: Int?              // BatteryCurrentCapacity（当前电量 %）
    var batteryIsCharging: Bool?        // BatteryIsCharging
    var batteryIsFullyCharged: Bool?    // BatteryIsFullyCharged
    var batterySerial: String?          // BatterySerialNumber
    // 基带
    var basebandVersion: String?        // BasebandVersion
    var basebandChipId: String?         // BasebandChipId
    var basebandStatus: String?         // BasebandStatus
    // 生产与验机（爱思「验机报告」核心）
    var effectiveProductionStatusAp: String?   // EffectiveProductionStatusAp
    var effectiveProductionStatusSep: String?  // EffectiveProductionStatusSEP
    var certificateProductionStatus: String?   // CertificateProductionStatus
    var fdrSealingStatus: String?              // FDRSealingStatus
    var internalBuild: Bool?                   // InternalBuild
    var configNumber: String?                  // ConfigNumber
    // 零部件序列号（爱思「硬件」页）
    var coverglassSerial: String?       // CoverglassSerialNumber
    var lunaFlexSerial: String?         // LunaFlexSerialNumber
    var mesaSerial: String?             // MesaSerialNumber
    var arcModuleSerial: String?        // ArcModuleSerialNumber
    // 状态
    var isChaperoned: Bool?             // com.apple.mobile.chaperone
    var developerModeStatus: Bool?      // DeveloperModeStatus
    var hasBaseband: Bool?              // HasBaseband
    var hasBattery: Bool?               // HasBattery
    // 功能支持（DeviceSupports* 全部键）
    var supportedFeatures: [String] = []
    // v0.3.291：lockdown 全量键值（与爱思设备信息页同源同量——爱思缓存的
    // <序列号>_info.txt 即lockdown GetValue 全量字典；此前只挑了部分键，
    // 故检测项远少于爱思）
    var allValues: [(String, String)] = []
    // v0.3.294：对齐爱思「设备详情」的派生子项（机型规格来自 DeviceCatalog）
    var releaseDate: String?          // 上市日期
    var cpuName: String?              // CPU 类型（Apple A16）
    var cpuFrequency: String?         // CPU 频率
    var screenInches: String?         // 屏幕尺寸（英寸）
    var regulatoryModel: String?      // 监管型号（A2846）
    var salesType: String?            // 销售类型（零售机/官换机…）
    var regionName: String?           // 销售地区名（美国）
    var timeZone: String?             // 时区
    var localeRegion: String?         // 地区（zh-Hans_JP）
    var uses24HourClock: Bool?        // 24 小时制
    var protocolVersion: String?      // 协议版本
    var partitionType: String?        // 分区类型
    var hardwareVersion: String?      // 硬件版本（t8120 → 8120）
    var simStatus: String?            // SIM 卡状态
    var simTrayStatus: String?        // SIM 卡托状态
    var carrier1: String?             // eSIM 卡1 运营商
    var carrier2: String?             // eSIM 卡2 运营商
    var wirelessBoardSerial: String?  // Wi-Fi 序列号
    var raw: [String: Any] = [:]
}

enum DeviceInfoService {
    /// v0.3.291：lockdown 字典 → 扁平键值对（嵌套字典/数组转字符串），按 key 排序.
    static func flatten(_ dict: [String: Any]) -> [(String, String)] {
        dict.compactMap { key, value -> (String, String)? in
            let text: String
            switch value {
            case let s as String:
                text = s
            case let b as Bool:
                text = b ? "true" : "false"
            case let n as NSNumber:
                text = n.stringValue
            case let a as [Any]:
                text = a.map { String(describing: $0) }.joined(separator: ", ")
            case let d as [String: Any]:
                text = d.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            default:
                text = String(describing: value)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (key, trimmed)
        }
        .sorted { $0.0 < $1.0 }
    }

    /// 收集完整设备信息（lockdown + AFC + MobileGestalt + sysctl）.
    /// 同步阻塞——调用方放到后台线程.
    static func collectFull() throws -> DeviceInfoModel {
        let machine = stringSysctl("hw.machine") ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        var cpuCount: Int = 0
        var cpuSize = MemoryLayout<Int>.size
        sysctlbyname("hw.ncpu", &cpuCount, &cpuSize, nil, 0)
        var mem: UInt64 = 0
        var memSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &memSize, nil, 0)
        var storageTotalGB = 0, storageFreeGB = 0
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            storageTotalGB = Int(total / 1024 / 1024 / 1024)
            storageFreeGB = Int(free / 1024 / 1024 / 1024)
        }

        // 隧道拿 lockdown 整棵字典（核心数据）
        let lockdown = (try? Self.lockdownFullDict()) ?? [:]
        let region = Self.parseRegion(lockdown["RegionInfo"] as? String)
        let isJailbroken = (try? Self.isacJailbroken()) ?? nil
        let productionSOC = lockdown["ProductionSOC"] as? Bool

        // MobileGestalt
        let (mgUniqueChip, mgMLB, mgBaseband) = (try? Self.mobilegestaltKeys()) ?? (nil, nil, nil)

        // v0.3.285：爱思同款域采集（逆向 idm_info.dll 得出的域清单）
        let itunes = (try? Self.lockdownDomainDict("com.apple.mobile.iTunes")) ?? [:]
        let batteryDomain = (try? Self.lockdownDomainDict("com.apple.mobile.battery")) ?? [:]
        let chaperone = (try? Self.lockdownDomainDict("com.apple.mobile.chaperone")) ?? [:]
        func intOf(_ v: Any?) -> Int? {
            if let n = v as? Int { return n }
            if let n = v as? NSNumber { return n.intValue }
            if let sv = v as? String { return Int(sv) }
            return nil
        }
        func boolOf(_ v: Any?) -> Bool? {
            if let b = v as? Bool { return b }
            if let n = v as? NSNumber { return n.boolValue }
            return nil
        }
        func stringOf(_ v: Any?) -> String? {
            if let sv = v as? String { return sv }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        let designCap = intOf(itunes["DesignCapacity"])
        let maxCap = intOf(itunes["AppleRawMaxCapacity"]) ?? intOf(itunes["MaxCapacity"])
        var healthPercent: Int? = nil
        if let d = designCap, let m = maxCap, d > 0 {
            healthPercent = Int((Double(m) / Double(d) * 100).rounded())
        }
        // DeviceSupports* 功能支持清单（键名集合）
        let featurePrefix = "DeviceSupports"
        let features: [String] = itunes.keys
            .filter { $0.hasPrefix(featurePrefix) && boolOf(itunes[$0]) == true }
            .map { String($0.dropFirst(featurePrefix.count)) }
            .sorted()

        // 磁盘域
        var totalDisk: Int64? = nil
        var totalData: Int64? = nil
        var totalSystem: Int64? = nil
        if let du = try? Self.lockdownDomainDict("com.apple.disk_usage") {
            totalDisk = (du["TotalDataCapacity"] as? Int).map(Int64.init)
                ?? (du["TotalDiskCapacity"] as? Int).map(Int64.init)
            totalData = (du["TotalDataCapacity"] as? Int).map(Int64.init)
            totalSystem = (du["TotalSystemCapacity"] as? Int).map(Int64.init)
        }

        // v0.3.294：爱思「设备详情」派生子项（机型规格查 DeviceCatalog 公开规格表）
        let spec = DeviceCatalog.spec(machine)
        func carrierOf(_ imsi: String?) -> String? {
            guard let imsi, imsi.count >= 5 else { return nil }
            return DeviceCatalog.carrierName(mcc: String(imsi.prefix(3)),
                                             mnc: String(imsi.dropFirst(3).prefix(2)))
        }
        let hardwareVersion: String? = {
            guard let platform = lockdown["HardwarePlatform"] as? String else { return nil }
            return platform.hasPrefix("t") ? String(platform.dropFirst()) : platform
        }()

        return DeviceInfoModel(
            modelName: Self.friendlyModel(machine),
            productType: machine,
            hardwareModel: lockdown["HardwareModel"] as? String,
            modelNumber: lockdown["ModelNumber"] as? String,
            deviceClass: lockdown["DeviceClass"] as? String,
            activationState: lockdown["ActivationState"] as? String,
            region: region,
            hardwarePlatform: lockdown["HardwarePlatform"] as? String,
            cpuArchitecture: lockdown["CPUArchitecture"] as? String,
            firmwareVersion: lockdown["FirmwareVersion"] as? String,
            buildVersion: lockdown["BuildVersion"] as? String,
            systemVersion: systemVersion,
            productionDevice: productionSOC.map { $0 ? "是" : "否" },
            jailbroken: isJailbroken,
            deviceName: lockdown["DeviceName"] as? String,
            deviceColor: lockdown["DeviceColor"] as? String,
            wiFiAddress: lockdown["WiFiAddress"] as? String,
            ethernetAddress: lockdown["EthernetAddress"] as? String,
            bluetoothAddress: lockdown["BluetoothAddress"] as? String,
            serialNumber: lockdown["SerialNumber"] as? String,
            imei: lockdown["InternationalMobileEquipmentIdentity"] as? String,
            imei2: lockdown["InternationalMobileEquipmentIdentity2"] as? String,
            imsi: lockdown["InternationalMobileSubscriberIdentity"] as? String,
            imsi2: lockdown["InternationalMobileSubscriberIdentity2"] as? String,
            udid: lockdown["UniqueDeviceID"] as? String,
            meid: lockdown["MobileEquipmentIdentifier"] as? String,
            ecid: mgUniqueChip.map { String($0) },
            mlbSerial: mgMLB,
            basebandSerial: mgBaseband,
            totalDiskBytes: totalDisk,
            totalDataBytes: totalData,
            totalSystemBytes: totalSystem,
            storageTotalGB: storageTotalGB,
            storageFreeGB: storageFreeGB,
            cpuCount: cpuCount,
            memoryMB: Int(mem / 1024 / 1024),
            designCapacity: designCap,
            maxCapacity: maxCap,
            batteryHealthPercent: healthPercent,
            cycleCount: intOf(itunes["CycleCount"]),
            batteryLevel: intOf(batteryDomain["BatteryCurrentCapacity"]) ?? intOf(itunes["BatteryCurrentCapacity"]),
            batteryIsCharging: boolOf(batteryDomain["BatteryIsCharging"]),
            batteryIsFullyCharged: boolOf(batteryDomain["BatteryIsFullyCharged"]),
            batterySerial: itunes["BatterySerialNumber"] as? String,
            basebandVersion: itunes["BasebandVersion"] as? String,
            basebandChipId: stringOf(itunes["BasebandChipId"]),
            basebandStatus: stringOf(itunes["BasebandStatus"]),
            effectiveProductionStatusAp: itunes["EffectiveProductionStatusAp"] as? String,
            effectiveProductionStatusSep: itunes["EffectiveProductionStatusSEP"] as? String,
            certificateProductionStatus: stringOf(itunes["CertificateProductionStatus"]),
            fdrSealingStatus: stringOf(itunes["FDRSealingStatus"]),
            internalBuild: boolOf(itunes["InternalBuild"]),
            configNumber: stringOf(itunes["ConfigNumber"]),
            coverglassSerial: itunes["CoverglassSerialNumber"] as? String,
            lunaFlexSerial: itunes["LunaFlexSerialNumber"] as? String,
            mesaSerial: itunes["MesaSerialNumber"] as? String,
            arcModuleSerial: itunes["ArcModuleSerialNumber"] as? String,
            isChaperoned: boolOf(chaperone["DeviceIsChaperoned"]) ?? boolOf(lockdown["DeviceIsChaperoned"]),
            developerModeStatus: boolOf(itunes["DeveloperModeStatus"]),
            hasBaseband: boolOf(itunes["HasBaseband"]),
            hasBattery: boolOf(itunes["HasBattery"]),
            supportedFeatures: features,
            allValues: Self.flatten(lockdown),
            releaseDate: spec?.releaseDate,
            cpuName: spec?.cpu,
            cpuFrequency: spec?.cpuFrequency,
            screenInches: spec?.screenInches,
            regulatoryModel: DeviceCatalog.regulatoryModel[machine],
            salesType: DeviceCatalog.salesType(lockdown["ModelNumber"] as? String),
            regionName: DeviceCatalog.regionName(lockdown["RegionInfo"] as? String),
            timeZone: lockdown["TimeZone"] as? String,
            localeRegion: lockdown["UserLocale"] as? String
                ?? lockdown["Locale"] as? String,
            uses24HourClock: boolOf(lockdown["Uses24HourClock"]),
            protocolVersion: stringOf(lockdown["ProtocolVersion"]),
            partitionType: lockdown["PartitionType"] as? String,
            hardwareVersion: hardwareVersion,
            simStatus: lockdown["SIMStatus"] as? String,
            simTrayStatus: lockdown["SIMTrayStatus"] as? String,
            carrier1: carrierOf(lockdown["InternationalMobileSubscriberIdentity"] as? String),
            carrier2: carrierOf(lockdown["InternationalMobileSubscriberIdentity2"] as? String),
            wirelessBoardSerial: lockdown["WirelessBoardSerialNumber"] as? String,
            raw: lockdown.merging(itunes) { a, _ in a }
        )
    }

    static func parseRegion(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return String(s.prefix(16))
    }

    // MARK: 隧道
    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }
    private static func pairingPath() -> String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }
    private static func makeTunnel() throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath()) else {
            throw NSError(domain: "DeviceInfo", code: -1, userInfo: [NSLocalizedDescriptionKey: "无配对文件"])
        }
        var pairingFile: OpaquePointer?
        if let e = pairingPath().withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw NSError(domain: "DeviceInfo", code: -2, userInfo: [NSLocalizedDescriptionKey: "读取配对文件失败"])
        }
        guard let pairingFile else { throw NSError(domain: "DeviceInfo", code: -3, userInfo: [NSLocalizedDescriptionKey: "配对文件解析失败"]) }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        let _ = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        var lastError: NSError?
        for _ in 0..<3 {
            var tunnel = TunnelHandles()
            let e = "EscapeSpaceDeviceInfo".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn, pairingFile, nil, nil, &tunnel.adapter, &tunnel.handshake)
                    }
                }
            }
            if e != nil {
                lastError = NSError(domain: "DeviceInfo", code: -5, userInfo: [NSLocalizedDescriptionKey: "创建隧道失败"])
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            }
            if let h = tunnel.handshake { rsd_handshake_free(h) }
            if let a = tunnel.adapter { adapter_free(a) }
        }
        throw lastError ?? NSError(domain: "DeviceInfo", code: -6, userInfo: [NSLocalizedDescriptionKey: "创建隧道失败"])
    }

    /// lockdown GetValue(None, None) → 整棵根字典
    static func lockdownFullDict() throws -> [String: Any] {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw NSError(domain: "DeviceInfo", code: -10, userInfo: [NSLocalizedDescriptionKey: "隧道未建立"])
        }
        var client: OpaquePointer?
        guard lockdownd_connect_rsd(adapter, handshake, &client) == nil, let client else {
            throw NSError(domain: "DeviceInfo", code: -11, userInfo: [NSLocalizedDescriptionKey: "连接 lockdownd 失败"])
        }
        defer { lockdownd_client_free(client) }
        var node: plist_t?
        guard lockdownd_get_value(client, nil, nil, &node) == nil, let node else {
            throw NSError(domain: "DeviceInfo", code: -12, userInfo: [NSLocalizedDescriptionKey: "GetValue 失败"])
        }
        defer { plist_free(node) }
        return Self.dictFromPlist(node)
    }

    static func lockdownDomainDict(_ domain: String) throws -> [String: Any] {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw NSError(domain: "DeviceInfo", code: -20, userInfo: [NSLocalizedDescriptionKey: "隧道未建立"])
        }
        var client: OpaquePointer?
        guard lockdownd_connect_rsd(adapter, handshake, &client) == nil, let client else {
            throw NSError(domain: "DeviceInfo", code: -21, userInfo: [NSLocalizedDescriptionKey: "连接失败"])
        }
        defer { lockdownd_client_free(client) }
        var node: plist_t?
        let rc = domain.withCString { domainCStr in
            lockdownd_get_value(client, nil, domainCStr, &node)
        }
        guard rc == nil, let node else {
            throw NSError(domain: "DeviceInfo", code: -22, userInfo: [NSLocalizedDescriptionKey: "GetValue 失败"])
        }
        defer { plist_free(node) }
        return Self.dictFromPlist(node)
    }

    private static func dictFromPlist(_ node: plist_t) -> [String: Any] {
        var binPtr: UnsafeMutablePointer<CChar>?
        var binLen: UInt32 = 0
        guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS,
              let binPtr, binLen > 0 else { return [:] }
        defer { plist_mem_free(binPtr) }
        return (try? PropertyListSerialization.propertyList(
            from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil) as? [String: Any]) ?? [:]
    }

    /// 越狱检测（iDescriptor utils.rs:497-502：afc list_dir ../../../../bin 非空）
    static func isacJailbroken() throws -> Bool {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else { return false }
        var afc: OpaquePointer?
        guard afc_client_connect_rsd(adapter, handshake, &afc) == nil, let afc else { return false }
        defer { afc_client_free(afc) }
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        guard afc_list_directory(afc, "/bin", &entries, &count) == nil else { return false }
        defer {
            if let entries {
                for i in 0..<count {
                    if let p = entries[i] { free(p) }
                }
                entries.deallocate()
            }
        }
        return count > 0
    }

    /// DiagnosticsRelay mobilegestalt 取 ECID / MLB / Baseband（一次传 keys 数组）
    static func mobilegestaltKeys() throws -> (Int64?, String?, String?) {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            return (nil, nil, nil)
        }
        var client: OpaquePointer?
        guard diagnostics_relay_client_connect_rsd(adapter, handshake, &client) == nil, let client else {
            return (nil, nil, nil)
        }
        defer { diagnostics_relay_client_free(client) }
        let keys: [String] = ["UniqueChipID", "MLBSerialNumber", "BasebandSerialNumber"]
        // const char ** keys 数组（不可变指针）
        let keyPtrs: [UnsafePointer<CChar>?] = keys.map { ($0 as NSString).utf8String }
        var node: plist_t?
        if let ffiError = keyPtrs.withUnsafeBufferPointer({ buf in
            diagnostics_relay_client_mobilegestalt(client, buf.baseAddress, UInt(buf.count), &node)
        }) {
            idevice_error_free(ffiError)
            return (nil, nil, nil)
        }
        guard let node else { return (nil, nil, nil) }
        defer { plist_free(node) }
        var binPtr: UnsafeMutablePointer<CChar>?
        var binLen: UInt32 = 0
        guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS,
              let binPtr, binLen > 0 else { return (nil, nil, nil) }
        defer { plist_mem_free(binPtr) }
        guard let dict = (try? PropertyListSerialization.propertyList(
            from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil)) as? [String: Any]
        else { return (nil, nil, nil) }
        // 响应可能为 { "UniqueChipID": {...} } 或 { key: value }；兼容两层
        func value(_ k: String) -> Any? {
            if let v = dict[k] { return v }
            if let sub = dict[k] as? [String: Any], let v = sub[k] { return v }
            return nil
        }
        var ecid: Int64? = nil
        if let v = value("UniqueChipID") {
            if let n = v as? Int { ecid = Int64(n) }
            else if let n = v as? Double { ecid = Int64(n) }
            else if let n = v as? Int64 { ecid = n }
            else if let s = v as? String { ecid = Int64(s) }
        }
        let mlb = value("MLBSerialNumber") as? String
        let bb = value("BasebandSerialNumber") as? String
        return (ecid, mlb, bb)
    }

    private static func stringSysctl(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// hw.machine → 中文机型名（v0.3.294：改走 DeviceCatalog 规格表，
    /// 修正此前表里缺 `iPhone15,4`（真机机型，会被退化成「iPhone 15,4」）
    /// 以及误填 `iPhone16,3/16,4`（Apple 无此标识）的问题）
    static func friendlyModel(_ machine: String) -> String {
        DeviceCatalog.name(machine)
    }
}