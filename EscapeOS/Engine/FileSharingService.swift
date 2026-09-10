import Foundation

/// v0.3.208：文档共享应用文件浏览（iDescriptor FileSharing 移植，不依赖漏洞）.
/// 数据源：
///   - instproxy_browse 列全部已装应用（含 UIFileSharingEnabled 字段）
///   - house_arrest_vend_documents 为指定 bundle id 拿 AFC 会话（仅该 App /Documents 容器）
///   - afc_list_directory / afc_get_file_info 列举与读元数据
struct FileSharingApp: Identifiable {
    var id: String { bundleId }
    var bundleId: String
    var name: String        // CFBundleDisplayName
    var version: String     // CFBundleShortVersionString
    var applicationType: String // "User" / "System"
    var supportsFileSharing: Bool
    var path: String?       // ApplicationPath（可选展示）
    var appSize: Int64?     // 应用大小（StaticDiskUsage / CFBundleSize，字节；未返回则为 nil）
    var docSize: Int64?     // 文档大小（DynamicDiskUsage，字节；未返回则 UI 层走 AFC 懒算）
    var appleId: String?    // 安装来源 Apple ID（iTunesMetadata.appleId，App Store 安装才有）
}

enum FileSharingService {
    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "FileSharing", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 列出全部已装应用并标 UIFileSharingEnabled.
    /// v0.3.271：主路径改 **Browse + ReturnAttributes**（pymobiledevice3 同款——
    /// StaticDiskUsage/DynamicDiskUsage/iTunesMetadata 只在带 ReturnAttributes 的
    /// 请求里返回，普通 Lookup 不带，这正是 v0.3.270 两个胶囊显示「—」的根因）；
    /// browse 失败回退原 get_apps 全字段 Lookup.
    /// 同步阻塞——调用方放后台线程.
    static func listAppsWithFileSharing() throws -> [FileSharingApp] {
        if let apps = try? browseAppsWithSizeAttributes(), !apps.isEmpty {
            return apps
        }
        return try legacyGetApps()
    }

    /// Browse + ReturnAttributes 主路径.
    private static func browseAppsWithSizeAttributes() throws -> [FileSharingApp] {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var ip: OpaquePointer?
        guard installation_proxy_connect_rsd(adapter, handshake, &ip) == nil, let ip else {
            throw makeError("连接 instproxy 失败")
        }
        defer { installation_proxy_client_free(ip) }

        let returnAttributes = [
            "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName",
            "CFBundleShortVersionString", "ApplicationType", "UIFileSharingEnabled",
            "Path", "StaticDiskUsage", "DynamicDiskUsage", "iTunesMetadata", "CFBundleSize",
        ]
        let optionsDict: [String: Any] = [
            "ClientOptions": ["ReturnAttributes": returnAttributes],
            "ApplicationType": "Any",
        ]
        let optionsData = try PropertyListSerialization.data(fromPropertyList: optionsDict, format: .binary, options: 0)

        var optionsPlist: plist_t?
        let buildRc = optionsData.withUnsafeBytes { (raw: UnsafeRawBuffer) -> plist_err_t in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return -1 }
            return plist_from_bin(base, UInt32(optionsData.count), &optionsPlist)
        }
        guard buildRc == PLIST_ERR_SUCCESS, let optionsPlist else {
            throw makeError("构造 Browse options 失败")
        }
        defer { plist_free(optionsPlist) }

        var rawApps: UnsafeMutableRawPointer?
        var count = 0
        if let ffiError = installation_proxy_browse(ip, optionsPlist, &rawApps, &count) {
            throw makeError("Browse 应用列表失败")
        }
        guard let rawApps, count > 0 else { return [] }

        let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
        defer {
            for index in 0..<count {
                plist_free(apps[index])
            }
            idevice_data_free(rawApps.assumingMemoryBound(to: UInt8.self),
                               UInt(count * MemoryLayout<plist_t?>.stride))
        }

        var result: [FileSharingApp] = []
        for index in 0..<count {
            var binaryPlist: UnsafeMutablePointer<CChar>?
            var binaryLength: UInt32 = 0
            guard plist_to_bin(apps[index], &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                  let binaryPlist, binaryLength > 0 else { continue }
            let data = Data(bytes: binaryPlist, count: Int(binaryLength))
            plist_mem_free(binaryPlist)
            guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                    as? [String: Any],
                  let bundleId = dict["CFBundleIdentifier"] as? String, !bundleId.isEmpty else { continue }
            if let app = parseAppDict(dict) { result.append(app) }
        }
        return result
    }

    /// dict → FileSharingApp（大小字段多来源防御：StaticDiskUsage/CFBundleSize →
    /// NSNumber/Int64 双形态）.
    private static func parseAppDict(_ dict: [String: Any]) -> FileSharingApp? {
        guard let bundleId = dict["CFBundleIdentifier"] as? String, !bundleId.isEmpty else { return nil }
        let name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String) ?? bundleId
        let version = (dict["CFBundleShortVersionString"] as? String) ?? ""
        let appType = (dict["ApplicationType"] as? String) ?? "Unknown"
        let sharing = (dict["UIFileSharingEnabled"] as? Bool) ?? false
        let appSize = (dict["StaticDiskUsage"] as? NSNumber)?.int64Value
            ?? (dict["CFBundleSize"] as? NSNumber)?.int64Value
        let docSize = (dict["DynamicDiskUsage"] as? NSNumber)?.int64Value
        let itunesMeta = dict["iTunesMetadata"] as? [String: Any]
        let appleId = (itunesMeta?["appleId"] as? String)
            ?? (itunesMeta?["bpsAccountID"] as? String)
            ?? (itunesMeta?["purchaseAccountID"] as? String)
        return FileSharingApp(
            bundleId: bundleId,
            name: name,
            version: version,
            applicationType: appType,
            supportsFileSharing: sharing,
            path: dict["Path"] as? String,
            appSize: appSize,
            docSize: docSize,
            appleId: appleId
        )
    }

    /// 原 get_apps（Lookup 全字段）实现——browse 失败时的回退.
    private static func legacyGetApps() throws -> [FileSharingApp] {
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

        // 2. get_apps（Lookup）—— 与 AppDiscovery / JITEnableService 同一范式
        var rawApps: UnsafeMutableRawPointer?
        var count = 0
        if let ffiError = installation_proxy_get_apps(ip, nil, nil, 0, &rawApps, &count) {
            throw makeError("获取应用列表失败")
        }
        guard let rawApps, count > 0 else { return [] }

        let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
        defer {
            for index in 0..<count {
                plist_free(apps[index])
            }
            idevice_data_free(rawApps.assumingMemoryBound(to: UInt8.self),
                               UInt(count * MemoryLayout<plist_t?>.stride))
        }

        var result: [FileSharingApp] = []
        for index in 0..<count {
            var binaryPlist: UnsafeMutablePointer<CChar>?
            var binaryLength: UInt32 = 0
            guard plist_to_bin(apps[index], &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                  let binaryPlist, binaryLength > 0 else { continue }
            let data = Data(bytes: binaryPlist, count: Int(binaryLength))
            plist_mem_free(binaryPlist)
            guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                    as? [String: Any] else { continue }
            if let app = parseAppDict(dict) { result.append(app) }
        }
        return result
    }

    /// 为指定 bundle id 建立 Documents 容器 AFC 会话（house_arrest vend_documents）.
    /// 返回 AFC handle（caller 负责 free）.失败 throw.
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

    /// v0.3.214：为指定 bundle id 建立**完整数据容器** AFC 会话（house_arrest vend_container）.
    /// 返回 AFC handle（caller 负责 free）；失败 throw —— 表示该应用不允许整个容器访问
    /// （多数第三方 App 无权限，仅开发者/受信签名 App 可开；此时降级只读 Documents）.
    static func openAppContainer(bundleId: String) throws -> OpaquePointer {
        var tunnel = try makeTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        var ha: OpaquePointer?
        guard house_arrest_client_connect_rsd(adapter, handshake, &ha) == nil, let ha else {
            throw makeError("连接 house_arrest 失败")
        }
        var afc: OpaquePointer?
        let rc = bundleId.withCString { bid in
            house_arrest_vend_container(ha, bid, &afc)
        }
        guard rc == nil, let afc else {
            throw makeError("该应用不允许访问完整容器（无权限）")
        }
        return afc
    }

    /// v0.3.270：计算指定 App Documents 容器的总大小（字节）.
    /// 每次新建 house_arrest 隧道 + AFC 递归遍历求和（Documents 树通常较小）.
    /// 调用方放后台线程、逐 App 串行（避免同时开多条隧道抢占）.
    static func computeDocumentsSize(bundleId: String) throws -> Int64 {
        let afc = try openAppDocuments(bundleId: bundleId)
        defer { afc_client_free(afc) }
        return try documentsSizeRecursively(afc: afc, path: "/")
    }

    private static func documentsSizeRecursively(afc: OpaquePointer, path: String) throws -> Int64 {
        var total: Int64 = 0
        for entry in try listDirectory(afc: afc, path: path) {
            if entry.isDirectory {
                total += try documentsSizeRecursively(afc: afc, path: entry.path)
            } else {
                total += fileSize(afc: afc, path: entry.path) ?? 0
            }
        }
        return total
    }

    /// v0.3.270：字节 → MB 可读文本（保留 2 位小数，与爱思格式一致）.
    static func formatMB(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        return String(format: "%.2f MB", mb)
    }

    // MARK: v0.3.214 文件操作（移植 FileBrowserView 能力：新建/重命名/删除）

    /// 新建目录
    static func makeDirectory(afc: OpaquePointer, path: String) throws {
        let rc = path.withCString { afc_make_directory(afc, $0) }
        guard rc == nil else { throw makeError("新建目录失败：\(path)") }
    }

    /// 重命名 / 移动
    static func rename(afc: OpaquePointer, from: String, to: String) throws {
        let rc = from.withCString { src in
            to.withCString { dst in afc_rename_path(afc, src, dst) }
        }
        guard rc == nil else { throw makeError("重命名失败：\(from)") }
    }

    /// 删除（目录需递归删 → 用 remove_path_and_contents）
    static func remove(afc: OpaquePointer, path: String, recursive: Bool) throws {
        let rc = path.withCString { cstr in
            if recursive {
                afc_remove_path_and_contents(afc, cstr)
            } else {
                afc_remove_path(afc, cstr)
            }
        }
        guard rc == nil else { throw makeError("删除失败：\(path)") }
    }

    /// 下载整个文件到内存（afc_file_read_entire 一次读，AFCService 同款范式）
    /// v0.3.226：0 字节空文件合法（新建空文件可编辑）；>200MB 才拒
    static func downloadFile(afc: OpaquePointer, path: String) throws -> Data {
        guard let size = fileSize(afc: afc, path: path), size <= 200 * 1024 * 1024 else {
            throw makeError("文件不存在或超过 200MB")
        }
        var handle: OpaquePointer?
        let rc = path.withCString { afc_file_open(afc, $0, AfcRdOnly, &handle) }
        guard rc == nil, let handle else { throw makeError("打开文件失败") }
        defer { afc_file_close(handle) }
        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        if let r = afc_file_read_entire(handle, &dataPtr, &length) {
            throw makeError("读取失败")
        }
        defer { if let dataPtr { afc_file_read_data_free(dataPtr, length) } }
        guard let dataPtr, length > 0 else { return Data() }
        return Data(bytes: dataPtr, count: length)
    }

    /// v0.3.227：流式下载到本地文件（1MB 分块读+写盘，不占内存，任意大小）+ 字节进度
    static func downloadFileStreaming(afc: OpaquePointer, path: String, to dest: URL,
                                      progress: @escaping (Int64, Int64) -> Void) throws {
        let total = fileSize(afc: afc, path: path) ?? 0
        var handle: OpaquePointer?
        let rc = path.withCString { afc_file_open(afc, $0, AfcRdOnly, &handle) }
        guard rc == nil, let handle else { throw makeError("打开文件失败：\(path)") }
        defer { afc_file_close(handle) }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: dest) else {
            throw makeError("创建本地文件失败：\(dest.lastPathComponent)")
        }
        defer { try? fh.close() }
        var done: Int64 = 0
        while true {
            var dataPtr: UnsafeMutablePointer<UInt8>? = nil
            var readLen: Int = 0
            let r = afc_file_read(handle, &dataPtr, 1_048_576, &readLen)
            if let dataPtr, readLen > 0 {
                fh.write(Data(bytes: dataPtr, count: readLen))
                afc_file_read_data_free(dataPtr, readLen)
                done += Int64(readLen)
                progress(done, total)
            }
            if r != nil { throw makeError("读取失败：\(path)") }
            if readLen <= 0 { break }
        }
    }

    /// 上传文件到 AFC（1MB 分块写，AFCService writeFile 同款）.父目录须已存在.
    static func uploadFile(afc: OpaquePointer, data: Data, to path: String) throws {
        var handle: OpaquePointer?
        let rc = path.withCString { afc_file_open(afc, $0, AfcWrOnly, &handle) }
        guard rc == nil, let handle else { throw makeError("创建文件失败：\(path)") }
        defer { afc_file_close(handle) }
        let chunkSize = 1_048_576
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let chunk = min(chunkSize, data.count - offset)
                if let r = afc_file_write(handle, base.advanced(by: offset), chunk) {
                    throw makeError("写入失败：\(path)")
                }
                offset += chunk
            }
        }
    }

    /// 列目录（AFC）.返回顶层条目名 + 是否目录.
    /// v0.3.213：错误不再吞成空数组——抛给 UI 显示真实原因.
    static func listDirectory(afc: OpaquePointer, path: String) throws -> [AfcEntry] {
        var entriesPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int = 0
        let rc = path.withCString { cstr in
            afc_list_directory(afc, cstr, &entriesPtr, &count)
        }
        guard rc == nil else {
            throw makeError("列目录失败：\(path)")
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
        guard let entriesPtr else { return [] }
        for i in 0..<count {
            guard let cstr = entriesPtr[i] else { continue }
            let name = String(cString: cstr)
            guard name != ".", name != ".." else { continue }
            let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
            let isDir = isDirectory(afc: afc, path: childPath)
            result.append(AfcEntry(name: name, path: childPath, isDirectory: isDir))
        }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 探测是否为目录（通过 afc_get_file_info 的 st_ifmt）
    static func isDirectory(afc: OpaquePointer, path: String) -> Bool {
        var info = AfcFileInfo()
        let rc = path.withCString { cstr in
            afc_get_file_info(afc, cstr, &info)
        }
        guard rc == nil else { return false }
        defer { afc_file_info_free(&info) }
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
        defer { afc_file_info_free(&info) }
        return rc == nil ? Int64(info.size) : nil
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