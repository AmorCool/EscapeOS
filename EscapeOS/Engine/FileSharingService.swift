import Foundation

/// v0.3.208：文档共享应用文件浏览（iDescriptor FileSharing 移植，不依赖漏洞）。
/// 数据源：
///   - instproxy_browse 列全部已装应用（含 UIFileSharingEnabled 字段）
///   - house_arrest_vend_documents 为指定 bundle id 拿 AFC 会话（仅该 App /Documents 容器）
///   - afc_list_directory / afc_get_file_info 列举与读元数据
struct FileSharingApp {
    var bundleId: String
    var name: String        // CFBundleDisplayName
    var version: String     // CFBundleShortVersionString
    var applicationType: String // "User" / "System"
    var supportsFileSharing: Bool
    var path: String?       // ApplicationPath（可选展示）
}

enum FileSharingService {
    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "FileSharing", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 列出全部已装应用并标 UIFileSharingEnabled（iDescriptor utils.rs:543）。
    /// 同步阻塞——调用方放后台线程。
    static func listAppsWithFileSharing() throws -> [FileSharingApp] {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        // 1. instproxy connect
        var ip: OpaquePointer?
        guard installation_proxy_connect_rsd(adapter, handshake, &ip) == nil, let ip else {
            throw makeError("连接 instproxy 失败")
        }
        defer { installation_proxy_client_free(ip) }

        // 2. browse(NULL) 拿所有 app 字典
        var nodesPtr: UnsafeMutablePointer<UnsafeMutablePointer<plist_t>?>?
        var nodesLen: Int = 0
        guard installation_proxy_browse(ip, nil, &nodesPtr, &nodesLen) == nil,
              let nodesPtr, nodesLen > 0 else {
            throw makeError("browse 失败")
        }
        defer {
            for i in 0..<nodesLen {
                if let p = nodesPtr[i] { plist_free(p) }
            }
            nodesPtr.deallocate()
        }

        var apps: [FileSharingApp] = []
        apps.reserveCapacity(nodesLen)
        for i in 0..<nodesLen {
            guard let p = nodesPtr[i] else { continue }
            guard let dict = plistToDict(p) else { continue }
            let bundleId = dict["CFBundleIdentifier"] as? String ?? ""
            let name = dict["CFBundleDisplayName"] as? String
                ?? dict["CFBundleName"] as? String ?? bundleId
            let version = dict["CFBundleShortVersionString"] as? String ?? ""
            let appType = dict["ApplicationType"] as? String ?? "Unknown"
            // UIFileSharingEnabled 字段（plist bool）
            let sharing = (dict["UIFileSharingEnabled"] as? Bool) ?? false
            apps.append(FileSharingApp(
                bundleId: bundleId,
                name: name,
                version: version,
                applicationType: appType,
                supportsFileSharing: sharing,
                path: dict["Path"] as? String
            ))
        }
        return apps
    }

    /// 为指定 bundle id 建立 Documents 容器 AFC 会话（house_arrest）。
    /// 返回 AFC handle（caller 负责 free）。失败 throw。
    static func openAppDocuments(bundleId: String) throws -> OpaquePointer {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var ha: OpaquePointer?
        guard house_arrest_client_connect_rsd(adapter, handshake, &ha) == nil, let ha else {
            throw makeError("连接 house_arrest 失败")
        }
        // vend_documents 会消费 ha（Rust 端 Box::from_raw → drop handle）
        var afc: OpaquePointer?
        let rc = bundleId.withCString { bid in
            house_arrest_vend_documents(ha, bid, &afc)
        }
        guard rc == nil, let afc else {
            throw makeError("无法为 \(bundleId) 取得 Documents AFC（可能未开启文档共享或未配对）")
        }
        return afc
    }

    /// 列目录（AFC）。返回顶层条目名 + 是否目录。
    static func listDirectory(afc: OpaquePointer, path: String) throws -> [AfcEntry] {
        var entriesPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int = 0
        let rc = path.withCString { cstr in
            afc_list_directory(afc, cstr, &entriesPtr, &count)
        }
        guard rc == nil, let entriesPtr, count > 0 else {
            return []
        }
        defer {
            if let entriesPtr {
                for i in 0..<count {
                    if let p = entriesPtr[i] { free(p) }
                }
                entriesPtr.deallocate()
            }
        }
        var result: [AfcEntry] = []
        for i in 0..<count {
            guard let cstr = entriesPtr[i] else { continue }
            let name = String(cString: cstr)
            guard name != ".", name != ".." else { continue }
            let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
            let isDir = isDirectory(afc: afc, path: childPath)
            result.append(AfcEntry(name: name, path: childPath, isDirectory: isDir))
        }
        return result.sorted {
            ($0.isDirectory, $0.name.lowercased()) < ($1.isDirectory, $1.name.lowercased())
        }
    }

    /// 探测是否为目录（通过 afc_get_file_info 的 st_ifmt）
    static func isDirectory(afc: OpaquePointer, path: String) -> Bool {
        var info = AfcFileInfo()
        let rc = path.withCString { cstr in
            afc_get_file_info(afc, cstr, &info)
        }
        guard rc == nil else { return false }
        if let p = info.st_ifmt {
            let s = String(cString: p)
            return s == "S_IFDIR"
        }
        return false
    }

    /// 读文件大小（字节）
    static func fileSize(afc: OpaquePointer, path: String) -> Int64? {
        var info = AfcFileInfo()
        let rc = path.withCString { cstr in
            afc_get_file_info(afc, cstr, &info)
        }
        return rc == nil ? Int64(info.size) : nil
    }

    // MARK: 辅助
    /// plist_t → [String: Any]
    static func plistToDict(_ node: plist_t) -> [String: Any]? {
        var binPtr: UnsafeMutablePointer<CChar>?
        var binLen: UInt32 = 0
        guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS,
              let binPtr, binLen > 0 else { return nil }
        defer { plist_mem_free(binPtr) }
        return try? PropertyListSerialization.propertyList(
            from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil) as? [String: Any]
    }

    // MARK: 隧道（拷贝自 DeviceInfoService 简化版）
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
            throw makeError("无配对文件")
        }
        var pairingFile: OpaquePointer?
        if let e = pairingPath().withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw makeError("读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("配对解析失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        let _ = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        var lastError: NSError?
        for _ in 0..<3 {
            var tunnel = TunnelHandles()
            let e = "EscapeSpaceFileShare".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn, pairingFile, nil, nil, &tunnel.adapter, &tunnel.handshake)
                    }
                }
            }
            if e != nil {
                lastError = makeError("建隧道失败")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            }
            if let h = tunnel.handshake { rsd_handshake_free(h) }
            if let a = tunnel.adapter { adapter_free(a) }
        }
        throw lastError ?? makeError("建隧道失败")
    }
}

struct AfcEntry: Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    var id: String { path }
}