import Foundation

/// 配置导入服务（汉化移植自 SideInstaller 的「配对 → 安装到应用」）。
///
/// 把当前配对文件（Documents/pairingFile.plist）写入设备上已安装的
/// 「支持列表」应用的容器 Documents 目录（如 SideStore 的
/// ALTPairingFile.mobiledevicepairing、Feather/StikDebug 的 pairingFile.plist），
/// 让这些应用能直接使用 EscapeSpace 的配对身份连上同一台设备。
///
/// 传输链路与 JIT / 虚拟定位完全一致：LocalDevVPN 隧道（RPPairing）→
/// house_arrest + AFC。不涉及原版 SideInstaller 的 LocalNetworkAuthorization
/// （NWBrowser/NWListener 本地网络权限探测）——那是它在生成配对文件时用来
/// 请求权限的，LiveContainer guest 等嵌入环境拿不到该权限；我们只做「写入」，
/// 用已有配对文件 + 系统 VPN 隧道，天然绕开这个 LC 兼容性问题。
final class PairingInstallService {

    static let shared = PairingInstallService()
    private init() {}

    /// 支持接收配对文件的应用表（移植自 SideInstaller 的 PairingTargetApp.all，
    /// 与 iLoader 的 PAIRING_APPS 一致）。remoteRelativePath 相对目标应用的
    /// Documents 目录。
    struct PairingTargetApp: Identifiable, Equatable {
        let name: String
        let remoteRelativePath: String
        /// 限制匹配 bundle id 包含该字符串（区分 App Store 版与侧载版 StikDebug）。
        let bundleIDContains: String?

        var id: String { name }

        static let all: [PairingTargetApp] = [
            .init(name: "SideStore",
                  remoteRelativePath: "ALTPairingFile.mobiledevicepairing",
                  bundleIDContains: nil),
            .init(name: "LiveContainer",
                  remoteRelativePath: "SideStore/Documents/ALTPairingFile.mobiledevicepairing",
                  bundleIDContains: nil),
            .init(name: "Feather",
                  remoteRelativePath: "pairingFile.plist",
                  bundleIDContains: nil),
            .init(name: "StikDebug",
                  remoteRelativePath: "pairingFile.plist",
                  bundleIDContains: nil),
            .init(name: "StikDebug（侧载版）",
                  remoteRelativePath: "rp_pairing_file.plist",
                  bundleIDContains: "com.stik.stikdebug"),
            .init(name: "StikTest",
                  remoteRelativePath: "stiktest_pairing.plist",
                  bundleIDContains: nil),
            .init(name: "Protokolle",
                  remoteRelativePath: "pairingFile.plist",
                  bundleIDContains: nil),
            .init(name: "Antrag",
                  remoteRelativePath: "pairingFile.plist",
                  bundleIDContains: nil),
            .init(name: "SparseBox",
                  remoteRelativePath: "pairingFile.plist",
                  bundleIDContains: nil),
            .init(name: "StikStore",
                  remoteRelativePath: "pairingFile.plist",
                  bundleIDContains: nil),
            .init(name: "ByeTunes",
                  remoteRelativePath: "pairing file/pairingFile.plist",
                  bundleIDContains: nil),
            .init(name: "Reynard",
                  remoteRelativePath: "pairingFile.plist",
                  bundleIDContains: nil),
        ]
    }

    /// 表项与安装的 bundle id 配对后的目标。
    struct InstalledTarget: Identifiable, Equatable {
        let app: PairingTargetApp
        let bundleID: String

        var id: String { bundleID }
        var name: String { app.name }
        var remoteRelativePath: String { app.remoteRelativePath }
    }

    /// EscapeSpace 的配对文件路径（与「应用」页 / JIT / 虚拟定位共用）。
    private var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "PairingInstall", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message: String
        if let cString = ffiError.pointee.message {
            message = String(cString: cString)
        } else {
            message = ""
        }
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return NSError(domain: "PairingInstall", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? fallback : message])
    }

    // MARK: - 隧道（与 JITEnableService 同源）

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    private func createTunnel() throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw makeError("未检测到配对文件。请先在「应用」页导入配对文件（需 LocalDevVPN + 开发者模式）。")
        }

        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw error(from: ffiError, fallback: "读取配对文件失败")
        }
        guard let pairingFile else { throw makeError("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian

        let deviceIP = LocalDevVPN.targetIP
        let parseResult = deviceIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard parseResult == 1 else {
            throw makeError("隧道 IP 无效：\(deviceIP)（请检查「设置 → 本地隧道」）")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = "EscapeSpacePairingInstall".withCString { hostname in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hostname,
                            pairingFile,
                            nil,
                            nil,
                            &tunnel.adapter,
                            &tunnel.handshake
                        )
                    }
                }
            }
            if let ffiError {
                lastError = error(from: ffiError, fallback: "创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = makeError("创建开发者隧道失败")
            }
            if attempt < 2 {
                usleep(useconds_t(300_000 * (attempt + 1)))
            }
        }
        throw lastError ?? makeError("创建开发者隧道失败（请确认 LocalDevVPN 已连接）")
    }

    // MARK: - 扫描支持的应用

    /// 通过安装代理列出已安装应用，匹配支持表（按显示名，侧载版 StikDebug
    /// 走 bundle id 分支），保持表顺序。
    func scanTargets() throws -> [InstalledTarget] {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }

        var client: OpaquePointer?
        if let ffiError = installation_proxy_connect_rsd(adapter, handshake, &client) {
            throw error(from: ffiError, fallback: "连接安装代理失败")
        }
        defer { installation_proxy_client_free(client) }
        guard let client else { throw makeError("连接安装代理失败") }

        var rawApps: UnsafeMutableRawPointer?
        var count = 0
        if let ffiError = installation_proxy_get_apps(client, nil, nil, 0, &rawApps, &count) {
            throw error(from: ffiError, fallback: "获取应用列表失败")
        }
        guard let rawApps, count > 0 else { return [] }

        let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
        defer {
            for index in 0..<count {
                plist_free(apps[index])
            }
            idevice_data_free(rawApps.assumingMemoryBound(to: UInt8.self), UInt(count * MemoryLayout<plist_t?>.stride))
        }

        var found: [(displayName: String, bundleID: String)] = []
        for index in 0..<count {
            var binaryPlist: UnsafeMutablePointer<CChar>?
            var binaryLength: UInt32 = 0
            guard plist_to_bin(apps[index], &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                  let binaryPlist, binaryLength > 0 else { continue }
            let data = Data(bytes: binaryPlist, count: Int(binaryLength))
            plist_mem_free(binaryPlist)

            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any],
                  let bundleID = dict["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else { continue }
            let displayName = (dict["CFBundleDisplayName"] as? String)
                ?? (dict["CFBundleName"] as? String)
                ?? bundleID
            found.append((displayName, bundleID))
        }

        var out: [InstalledTarget] = []
        var seen = Set<String>()
        for app in found {
            let entry: PairingTargetApp?
            if app.displayName == "StikDebug" {
                let sideloaded = app.bundleID.contains("com.stik.stikdebug")
                entry = PairingTargetApp.all.first {
                    $0.name == (sideloaded ? "StikDebug（侧载版）" : "StikDebug")
                }
            } else {
                entry = PairingTargetApp.all.first { $0.name == app.displayName && $0.bundleIDContains == nil }
            }
            guard let entry, seen.insert(entry.name).inserted else { continue }
            out.append(InstalledTarget(app: entry, bundleID: app.bundleID))
        }
        return out.sorted {
            (PairingTargetApp.all.firstIndex(of: $0.app) ?? .max)
                < (PairingTargetApp.all.firstIndex(of: $1.app) ?? .max)
        }
    }

    // MARK: - 写入配对文件

    /// 把配对文件写入一个目标应用，读回验证字节数。
    @discardableResult
    func installPairing(into target: InstalledTarget) throws -> Int {
        let data = try Data(contentsOf: URL(fileURLWithPath: pairingPath))
        guard !data.isEmpty else { throw makeError("配对文件为空") }
        return try writeFile(intoBundleID: target.bundleID,
                             remoteRelativePath: target.remoteRelativePath,
                             data: data)
    }

    /// 写入全部目标（一个失败不阻塞其余，返回失败列表）。
    func installPairing(intoAll targets: [InstalledTarget]) throws -> [String] {
        var failures: [String] = []
        for target in targets {
            do {
                _ = try installPairing(into: target)
            } catch {
                failures.append("\(target.name)（\(error.localizedDescription)）")
            }
        }
        return failures
    }

    /// house_arrest + AFC 写入并读回验证（对齐 SideInstaller 的
    /// DeviceConnection.writeFile）。
    @discardableResult
    private func writeFile(intoBundleID bundleID: String,
                           remoteRelativePath: String,
                           data: Data) throws -> Int {
        var tunnel = try createTunnel()
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("隧道未建立")
        }
        guard !data.isEmpty else { throw makeError("拒绝写入空文件") }

        var ha: OpaquePointer?
        if let ffiError = house_arrest_client_connect_rsd(adapter, handshake, &ha) {
            throw error(from: ffiError, fallback: "连接 house_arrest 失败")
        }
        guard ha != nil else { throw makeError("house_arrest 客户端为空") }

        // vend_documents 会消费 ha（成功失败都一样），绝不能 free。
        var afc: OpaquePointer?
        let vendErr = bundleID.withCString { house_arrest_vend_documents(ha, $0, &afc) }
        if let vendErr {
            throw error(from: vendErr, fallback: "获取 \(bundleID) 容器失败")
        }
        guard let afc else { throw makeError("获取容器 AFC 客户端失败") }
        defer { afc_client_free(afc) }

        // vend_documents 的根在容器本身（容器根只读），路径带 /Documents/。
        let remotePath = "/Documents/\(remoteRelativePath)"
        makeRemoteDirectories(afc, forFileAt: remotePath)

        var wfile: OpaquePointer?
        if let ffiError = remotePath.withCString({ afc_file_open(afc, $0, AfcWr, &wfile) }) {
            throw error(from: ffiError, fallback: "打开 \(remotePath) 失败")
        }
        guard let wfile else { throw makeError("AFC 写入句柄为空") }
        do {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                if let ffiError = afc_file_write(wfile, base, data.count) {
                    throw error(from: ffiError, fallback: "写入失败")
                }
            }
        } catch {
            _ = afc_file_close(wfile)
            throw error
        }
        if let ffiError = afc_file_close(wfile) {
            throw error(from: ffiError, fallback: "关闭写入句柄失败（写入未提交）")
        }

        // 读回验证。
        var rfile: OpaquePointer?
        if let ffiError = remotePath.withCString({ afc_file_open(afc, $0, AfcRdOnly, &rfile) }) {
            throw error(from: ffiError, fallback: "读回打开失败")
        }
        guard let rfile else { throw makeError("AFC 读回句柄为空") }
        var rdata: UnsafeMutablePointer<UInt8>?
        var rlen = 0
        let readErr = afc_file_read_entire(rfile, &rdata, &rlen)
        _ = afc_file_close(rfile)
        if let rdata { afc_file_read_data_free(rdata, rlen) }
        if let readErr {
            throw error(from: readErr, fallback: "读回失败")
        }
        guard rlen == data.count else {
            throw makeError("读回字节数不符：写入 \(data.count) 字节，设备端 \(rlen) 字节")
        }
        return rlen
    }

    /// 逐级创建目标文件的父目录（AFC 无 mkdir -p）。
    private func makeRemoteDirectories(_ afc: OpaquePointer, forFileAt remoteFilePath: String) {
        let components = remoteFilePath.split(separator: "/").dropLast()
        var path = ""
        for component in components {
            path += "/\(component)"
            _ = path.withCString { afc_make_directory(afc, $0) }  // 已存在则忽略错误
        }
    }
}
