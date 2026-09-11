import Foundation

/// v0.3.293：硬盘/闪存详情（移植爱思「硬盘详情」面板）
///
/// 数据源：`diagnostics_relay` 的 IORegistry → **AppleEmbeddedNVMeController** 节点。
/// 真机 iPhone15,4 / iOS 27.0 实测返回 46 个键，与爱思面板字段**逐项对应**
/// （vendor-name=Toshiba / Model Number=APPLE SSD AP0512Z / chip-id=S5E /
///  firmware-version=590 / controller-unique-id=0ba01ef38134201a /
///  nand-marketing-name=tlc_3d_g5_2p_512 / msp-version=4.12.2.0.0.0）。
///
/// 对照来源：逆向 idm_info.dll 的 `ios_get_detailed_battery_info` 尾部——
/// 它在电池数据之后继续读 `AppleEmbeddedNVMeController` / `IOFlashMedia` / `ASPStorage`
/// 的 `controllers`→`dies`→`die-chip-id`、`nand-marketing-name`、`Device/Controller Characteristics`
/// 等键，即爱思硬盘详情面板的实现路径。
struct StorageDetailInfo {
    // 基本
    var flashVendor: String?      // 闪存颗粒厂商（Controller Characteristics.vendor-name）
    var deviceVendor: String?     // 硬盘厂商（Vendor Name）
    var marketingName: String?    // Nand 闪存名（nand-marketing-name）
    var modelNumber: String?      // 硬盘型号（Model Number）
    var chipID: String?           // 芯片型号（chip-id）
    var firmwareVersion: String?  // 固件版本（firmware-version / Firmware Revision）
    var mspVersion: String?       // MSP 版本（msp-version）
    var serialNumber: String?     // 序列号（controller-unique-id / Serial Number）
    var cellType: String?         // 闪存类型（default-bits-per-cell → SLC/MLC/TLC/QLC）
    var capacityBytes: Int64?     // 容量（capacity）
    var encryptionType: String?   // 加密类型（Encryption Type）
    var nandStatus: String?       // AppleNANDStatus
    var nvmeRevision: String?     // NVMe Revision Supported
    var interconnect: String?     // Physical Interconnect
    var fragmentation: Int?       // nand-fragmentation
    // IO 参数
    var maxSegmentByteCountRead: Int?     // 最大读取字节数
    var maxSegmentByteCountWrite: Int?    // 最大写入字节数
    var maxSegmentCountRead: Int?         // 最大读取数
    var maxSegmentCountWrite: Int?        // 最大写入数
    var maxSwapWrite: Int64?              // 最大写入交换量
    var minSegmentAlignmentByteCount: Int? // 最小段对齐字节数
    var minSaturationByteCount: Int?      // 最小饱和字节数
    var preferredIOSize: Int?             // 首选 IO 大小
    var maxByteCountRead: Int?            // 单次最大读字节（IOMaximumByteCountRead）
    var maxByteCountWrite: Int?           // 单次最大写字节（IOMaximumByteCountWrite）
    // 颗粒结构
    var pageSize: Int?                    // 页大小
    var pagesPerBlockMLC: Int?            // 每块页数（MLC）
    var pagesPerBlockSLC: Int?            // 每块页数（SLC）
    var numBus: Int?                      // 总线数
    var diesPerBus: [Int] = []            // 每总线 die 数
    var cauPerDie: Int?                   // 每 die 的 CAU
    var numDip: Int?                      // DIP 数
    var blocksPerCau: Int?                // 每 CAU 块数
    var raw: [String: Any] = [:]
}

enum StorageDetailService {
    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "StorageDetail", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func ffiError(_ e: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let e else { return makeError(fallback) }
        defer { idevice_error_free(e) }
        let msg = e.pointee.message.map { String(cString: $0) } ?? ""
        return NSError(domain: "StorageDetail", code: Int(e.pointee.code),
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
            throw makeError("未检测到配对文件，请先在「应用管理」导入配对文件（需 LocalDevVPN + 开发者模式）")
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
            let e = "EscapeSpaceStorage".withCString { hn in
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

    /// 读取硬盘详情（同步阻塞——调用方放后台线程）
    static func fetch() throws -> StorageDetailInfo {
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

    private static func query(client: OpaquePointer) throws -> StorageDetailInfo {
        var node: plist_t?
        if let e = diagnostics_relay_client_ioregistry(client, nil, nil,
                                                      "AppleEmbeddedNVMeController", &node) {
            throw ffiError(e, fallback: "查询闪存 IORegistry 失败")
        }
        defer { if let node { plist_free(node) } }
        guard let node else {
            throw makeError("未返回闪存数据（设备可能未解锁，或该机型不支持）")
        }
        var binPtr: UnsafeMutablePointer<CChar>?
        var binLen: UInt32 = 0
        guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS, let binPtr, binLen > 0 else {
            throw makeError("闪存 plist 序列化失败")
        }
        defer { plist_mem_free(binPtr) }
        let data = Data(bytes: binPtr, count: Int(binLen))
        guard let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any] else {
            throw makeError("闪存 plist 解析失败")
        }
        return parse(dict)
    }

    /// IORegistry 字典 → 模型
    static func parse(_ dict: [String: Any]) -> StorageDetailInfo {
        let ctrl = dict["Controller Characteristics"] as? [String: Any] ?? [:]
        let device = dict["Device Characteristics"] as? [String: Any] ?? [:]

        func str(_ key: String, _ d: [String: Any]) -> String? {
            if let s = d[key] as? String, !s.isEmpty { return s }
            if let n = d[key] as? NSNumber { return n.stringValue }
            return nil
        }
        func int(_ key: String, _ d: [String: Any]) -> Int? {
            if let n = d[key] as? Int { return n }
            if let n = d[key] as? NSNumber { return n.intValue }
            if let s = d[key] as? String { return Int(s) }
            return nil
        }

        // 闪存类型：default-bits-per-cell 1=SLC 2=MLC 3=TLC 4=QLC
        let bits = int("default-bits-per-cell", ctrl) ?? int("default-bits-per-cell", device)
        let cellType: String? = {
            switch bits {
            case 1: return "SLC"
            case 2: return "MLC"
            case 3: return "TLC"
            case 4: return "QLC"
            case .some(let b): return "\(b) bit/cell"
            default: return nil
            }
        }()

        let dies = (ctrl["dies-per-bus"] as? [Any])?.compactMap { v -> Int? in
            if let n = v as? Int { return n }
            if let n = v as? NSNumber { return n.intValue }
            return nil
        } ?? []

        return StorageDetailInfo(
            flashVendor: str("vendor-name", ctrl),
            deviceVendor: str("Vendor Name", dict),
            marketingName: str("nand-marketing-name", ctrl) ?? str("nand-marketing-name", device),
            modelNumber: str("Model Number", dict),
            chipID: str("chip-id", ctrl) ?? str("chip-id", device),
            firmwareVersion: str("firmware-version", ctrl) ?? str("Firmware Revision", dict),
            mspVersion: str("msp-version", ctrl),
            serialNumber: str("controller-unique-id", ctrl) ?? str("Serial Number", dict),
            cellType: cellType,
            capacityBytes: (ctrl["capacity"] as? NSNumber)?.int64Value
                ?? (ctrl["capacity"] as? Int).map(Int64.init),
            encryptionType: str("Encryption Type", ctrl),
            nandStatus: str("AppleNANDStatus", dict),
            nvmeRevision: str("NVMe Revision Supported", dict),
            interconnect: str("Physical Interconnect", dict),
            fragmentation: int("nand-fragmentation", dict),
            maxSegmentByteCountRead: int("IOMaximumSegmentByteCountRead", dict),
            maxSegmentByteCountWrite: int("IOMaximumSegmentByteCountWrite", dict),
            maxSegmentCountRead: int("IOMaximumSegmentCountRead", dict),
            maxSegmentCountWrite: int("IOMaximumSegmentCountWrite", dict),
            maxSwapWrite: (dict["IOMaximumSwapWrite"] as? NSNumber)?.int64Value,
            minSegmentAlignmentByteCount: int("IOMinimumSegmentAlignmentByteCount", dict),
            minSaturationByteCount: int("IOMinimumSaturationByteCount", dict),
            preferredIOSize: int("Preferred IO Size", ctrl),
            maxByteCountRead: int("IOMaximumByteCountRead", dict),
            maxByteCountWrite: int("IOMaximumByteCountWrite", dict),
            pageSize: int("page-size", ctrl),
            pagesPerBlockMLC: int("pages-per-block-mlc", ctrl),
            pagesPerBlockSLC: int("pages-per-block-slc", ctrl),
            numBus: int("num-bus", ctrl),
            diesPerBus: dies,
            cauPerDie: int("cau-per-die", ctrl),
            numDip: int("num-dip", ctrl),
            blocksPerCau: int("blocks-per-cau", ctrl),
            raw: dict
        )
    }
}
