import Foundation
import UIKit

/// v0.3.207：设备信息 —— 参考 iDescriptor 信息面板（DeviceInfo）。
/// 本机可拿（sysctl + UIDevice，无需配对）：型号标识 hw.machine、系统版本、
/// CPU 核数、内存、可用存储；隧道扩展（配对后）：设备序列号。
struct DeviceInfoModel {
    var productType: String       // hw.machine: "iPhone13,1"
    var modelName: String         // 映射中文名: "iPhone 12 mini"
    var systemVersion: String     // 25.x
    var cpuCount: Int             // 核数
    var memoryMB: Int             // 物理内存
    var storageTotalGB: Int       // 总存储
    var storageFreeGB: Int        // 可用存储
    var serialNumber: String?     // 配对后从 lockdown 拿
    var deviceName: String?       // 配对后从 lockdown 拿
}

enum DeviceInfoService {
    static func collectLocal() -> DeviceInfoModel {
        let machine = Self.stringSysctl("hw.machine") ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        var cpuCount: Int = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.ncpu", &cpuCount, &size, nil, 0)
        var mem: UInt64 = 0
        var memSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &memSize, nil, 0)
        let memoryMB = Int(mem / 1024 / 1024)

        // 存储（Home 目录所在卷）
        var storageTotalGB = 0, storageFreeGB = 0
        if let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()) {
            let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            storageTotalGB = Int(total / 1024 / 1024 / 1024)
            storageFreeGB = Int(free / 1024 / 1024 / 1024)
        }

        return DeviceInfoModel(
            productType: machine,
            modelName: Self.friendlyModel(machine),
            systemVersion: systemVersion,
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            storageTotalGB: storageTotalGB,
            storageFreeGB: storageFreeGB,
            serialNumber: nil,
            deviceName: nil
        )
    }

    /// 配对后补充设备序列号（lockdown GetValue，需 LocalDevVPN）
    static func enrichWithLockdown(_ info: DeviceInfoModel) -> DeviceInfoModel {
        var result = info
        do {
            var tunnel = try makeTunnel()
            defer { tunnel.free() }
            guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else { return result }
            var client: OpaquePointer?
            guard lockdownd_connect_rsd(adapter, handshake, &client) == nil, let client else { return result }
            defer { lockdownd_client_free(client) }
            var node: plist_t?
            guard lockdownd_get_value(client, nil, nil, &node) == nil, let node else { return result }
            defer { plist_free(node) }
            var binPtr: UnsafeMutablePointer<CChar>?
            var binLen: UInt32 = 0
            guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS,
                  let binPtr, binLen > 0 else { return result }
            defer { plist_mem_free(binPtr) }
            if let dict = try? PropertyListSerialization.propertyList(
                from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil) as? [String: Any] {
                result.serialNumber = dict["SerialNumber"] as? String
                result.deviceName = dict["DeviceName"] as? String
            }
        } catch {}
        return result
    }

    private static func stringSysctl(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// hw.machine → 中文机型名（覆盖常见 iPhone/iPad）
    static func friendlyModel(_ machine: String) -> String {
        let table: [String: String] = [
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone14,5": "iPhone 13", "iPhone14,4": "iPhone 13 mini",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd)",
            "iPhone11,8": "iPhone XR", "iPhone11,2": "iPhone XS",
            "iPhone11,6": "iPhone XS Max", "iPhone10,3": "iPhone X",
            "iPhone10,6": "iPhone X", "iPhone10,1": "iPhone 8",
            "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus",
            "iPhone10,5": "iPhone 8 Plus", "iPhone9,1": "iPhone 7",
            "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus",
            "iPhone9,4": "iPhone 7 Plus", "iPhone8,1": "iPhone 6s",
            "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE (1st)",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone16,3": "iPhone 15", "iPhone16,4": "iPhone 15 Plus",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
        ]
        if let name = table[machine] { return name }
        if machine.hasPrefix("iPhone") { return machine.replacingOccurrences(of: "iPhone", with: "iPhone ") }
        return machine
    }

    // MARK: 隧道（同 BatteryHealthService 模式，避免循环依赖故内联）
    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }
    private static func makeTunnel() throws -> TunnelHandles {
        let pairingPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw NSError(domain: "DeviceInfo", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无配对文件（序列号需配对）"])
        }
        var pairingFile: OpaquePointer?
        if let e = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw NSError(domain: "DeviceInfo", code: -2, userInfo: [NSLocalizedDescriptionKey: "配对文件读取失败"])
        }
        guard let pairingFile else { throw NSError(domain: "DeviceInfo", code: -3,
            userInfo: [NSLocalizedDescriptionKey: "配对文件解析失败"]) }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else { throw NSError(domain: "DeviceInfo", code: -4,
            userInfo: [NSLocalizedDescriptionKey: "隧道 IP 无效"]) }

        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let e = "EscapeSpaceDeviceInfo".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn, pairingFile, nil, nil, &tunnel.adapter, &tunnel.handshake)
                    }
                }
            }
            if let e {
                lastError = NSError(domain: "DeviceInfo", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "创建隧道失败"])
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? NSError(domain: "DeviceInfo", code: -6,
            userInfo: [NSLocalizedDescriptionKey: "创建隧道失败"])
    }
}