import Foundation
import UIKit

/// 顽固图标清理 —— 移植自爱思 9.0「删除顽固图标」.
///
/// ## 它解决什么
/// 装 App 失败 / 中途取消之后，桌面上会留下**点不开也删不掉**的残留图标
/// （白图标 / 灰图标 / 无名称图标）。这些图标在 SpringBoard 的**桌面布局**里
/// 还占着一个位置，但对应的 App 早就不在设备上了。
///
/// ## 原理（逆向爱思 + 公开资料核对）
/// 走 `com.apple.springboardservices` 的两个命令：
/// 1. `getIconState` —— 读出**整份**桌面布局；
/// 2. `setIconState` —— 把改过的布局**整份**写回。
///
/// 判定「顽固」的判据：**布局里的 bundle id 不在「已安装应用清单」里**。
/// 必须按 bundle id 比对，**不能按显示名** —— 同名应用是存在的，而且
/// WhatsApp 的显示名里带一个不可见字符，按名字比会误判。
///
/// ## 安全设计（三条）
/// 1. **扫描是只读的** —— 不改设备上任何东西；
/// 2. 写回前**一定**先把原始布局备份到 `Documents/IconStateBackup/`，
///    界面提供「恢复图标位置」一键回滚；
/// 3. 读和写**用同一个 formatVersion**（`"2"` = 扁平列表，信息最全）。
///
/// ## 已知边界（如实写出来，别当成 bug）
/// - `setIconState` 对「**已安装但不在桌面**的应用」无效 —— iOS 会把它放回新页。
///   本功能只删「应用已经不在设备上」的残留，不受这条限制影响。
/// - 布局里**不携带小组件**，所以小组件相关问题处理不了。
/// - `formatVersion` 1/3 是固定网格，尾部 `false` 是**填充格**不是间隙 —— 这里统一用 `"2"`。
enum IconCleanupService {

    /// 读写布局用的 formatVersion。**读写必须一致**，否则设备可能拒绝。
    private static let formatVersion = "2"

    // MARK: - 类型

    /// 顽固图标的两类成因
    enum GhostKind: String {
        /// 布局里有 bundle id，但设备上没装这个应用（白图标 / 灰图标多数属于这类）
        case missingApp
        /// 布局里既没有 bundle id 也没有显示名（点不开的空白图标）
        case nameless

        var label: String {
            switch self {
            case .missingApp: return "应用已不在设备上"
            case .nameless: return "无 bundle id / 无名称"
            }
        }
    }

    /// 一个被判定为「顽固」的图标
    struct GhostIcon: Identifiable, Equatable {
        let id = UUID()
        let kind: GhostKind
        /// 布局里的 bundle id（`nameless` 类可能为空）
        let bundleID: String
        /// 布局里的显示名（可能为空）
        let displayName: String
        /// 位置描述，如「第 2 页」「第 1 页 · 文件夹「工具」」
        let location: String

        /// 去重/匹配用的稳定签名 —— 只由布局里的字段算出来，不含位置
        var signature: String { bundleID + "\u{1}" + displayName }
    }

    struct ScanResult {
        /// 判定为顽固的图标（界面上让用户逐条确认）
        let ghosts: [GhostIcon]
        /// 布局里一共多少个图标位
        let iconCount: Int
        /// 设备上装了多个 App
        let installedCount: Int
        /// 原始布局（备份用，写回前必须存下来）
        let rawState: Data
    }

    enum CleanupError: LocalizedError {
        case noPairingFile
        case tunnelFailed(String)
        case connectFailed(String)
        case readFailed(String)
        case parseFailed(String)
        case writeFailed(String)
        case noBackup

        var errorDescription: String? {
            switch self {
            case .noPairingFile:
                return "未检测到配对文件.请先导入配对文件（需 LocalDevVPN + 开发者模式）"
            case .tunnelFailed(let m):
                return "建立隧道失败：\(m)"
            case .connectFailed(let m):
                return "连接主屏服务失败：\(m)"
            case .readFailed(let m):
                return "读取桌面布局失败：\(m)"
            case .parseFailed(let m):
                return "桌面布局解析失败：\(m)"
            case .writeFailed(let m):
                return "写回桌面布局失败：\(m)"
            case .noBackup:
                return "还没有备份过图标位置"
            }
        }
    }

    // MARK: - 路径

    private static var pairingPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairingFile.plist").path
    }

    /// 备份目录：`Documents/IconStateBackup/`
    static var backupDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IconStateBackup", isDirectory: true)
    }

    /// 「最近一次」的备份 —— 恢复走这一份
    static var latestBackupURL: URL {
        backupDirectory.appendingPathComponent("latest.bin")
    }

    /// 是否已有可恢复的备份
    static var hasBackup: Bool {
        FileManager.default.fileExists(atPath: latestBackupURL.path)
    }

    /// 备份时间（没有备份返回 nil）
    static var backupDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: latestBackupURL.path))?[.modificationDate] as? Date
    }

    // MARK: - 隧道 + 服务连接

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    /// 建隧道（与 `JITEnableService` / `AFCService` 同款做法：3 次重试 + 短退避）.
    private static func makeTunnel(hostname: String) throws -> TunnelHandles {
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw CleanupError.noPairingFile
        }
        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            let m = message(from: ffiError, fallback: "读取配对文件失败")
            throw CleanupError.tunnelFailed(m)
        }
        guard let pairingFile else { throw CleanupError.tunnelFailed("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw CleanupError.tunnelFailed("隧道 IP 无效：\(deviceIP)")
        }

        var lastError: String?
        for attempt in 0..<3 {
            var tunnel = TunnelHandles()
            let ffiError = hostname.withCString { hostname in
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
                lastError = message(from: ffiError, fallback: "创建开发者隧道失败")
            } else if tunnel.adapter != nil, tunnel.handshake != nil {
                return tunnel
            } else {
                var incomplete = tunnel
                incomplete.free()
                lastError = "创建开发者隧道失败"
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw CleanupError.tunnelFailed(lastError ?? "创建开发者隧道失败")
    }

    /// 建隧道 + 连主屏服务。`body` 拿到客户端句柄，返回前自动释放.
    ///
    /// ⚠️ 整段必须在**后台线程**跑（建隧道是秒级 IO）。
    private static func withClient<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var tunnel = try makeTunnel(hostname: "EscapeSpaceIconClean")
        defer { tunnel.free() }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw CleanupError.tunnelFailed("隧道未建立")
        }

        var client: OpaquePointer?
        if let ffiError = springboard_services_connect_rsd(adapter, handshake, &client) {
            throw CleanupError.connectFailed(message(from: ffiError, fallback: "连接主屏服务失败"))
        }
        defer { springboard_services_free(client) }
        guard let client else { throw CleanupError.connectFailed("连接主屏服务失败") }
        return try body(client)
    }

    /// 把 FFI 错误转成可读文案（读完即释放）.
    private static func message(from ffiError: UnsafeMutablePointer<IdeviceFfiError>, fallback: String) -> String {
        let code = ffiError.pointee.code
        let text = ffiError.pointee.message.map { String(cString: $0) } ?? ""
        idevice_error_free(ffiError)
        return text.isEmpty ? "\(fallback)（code=\(code)）" : text
    }

    // MARK: - 读 / 写布局

    /// 读整份桌面布局（二进制 plist 字节）
    private static func readState() throws -> Data {
        try withClient { client in
            var raw: UnsafeMutableRawPointer?
            var length = 0
            let ffiError = formatVersion.withCString { fmt in
                springboard_services_get_icon_state(client, fmt, &raw, &length)
            }
            if let ffiError {
                throw CleanupError.readFailed(message(from: ffiError, fallback: "读取桌面布局失败"))
            }
            guard let raw, length > 0 else { throw CleanupError.readFailed("设备返回的布局为空") }
            // Rust 侧分配（into_boxed_slice），必须用 Rust 侧释放函数.
            defer { idevice_data_free(raw.assumingMemoryBound(to: UInt8.self), UInt(length)) }
            return Data(bytes: raw, count: length)
        }
    }

    /// 把一份布局写回设备
    private static func writeState(_ state: Data) throws {
        try withClient { client in
            let ffiError: UnsafeMutablePointer<IdeviceFfiError>? = state.withUnsafeBytes { buffer in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return formatVersion.withCString { fmt in
                    springboard_services_set_icon_state(client, base, state.count, fmt)
                }
            }
            if let ffiError {
                throw CleanupError.writeFailed(message(from: ffiError, fallback: "写回桌面布局失败"))
            }
        }
    }

    // MARK: - 解析 / 判定

    /// 布局根：一个「页」数组，每页又是一个条目数组.
    private static func parse(_ data: Data) throws -> [Any] {
        let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let pages = obj as? [Any] else {
            throw CleanupError.parseFailed("根节点不是数组")
        }
        return pages
    }

    /// 一个条目是不是「文件夹」（带 `iconLists`）
    private static func isFolder(_ entry: [String: Any]) -> Bool {
        entry["iconLists"] != nil
    }

    /// 条目 → 签名（与 `GhostIcon.signature` 同构）
    private static func signature(bundleID: String, displayName: String) -> String {
        bundleID + "\u{1}" + displayName
    }

    private static func entrySignature(_ entry: [String: Any]) -> String {
        signature(bundleID: (entry["bundleIdentifier"] as? String) ?? "",
                  displayName: (entry["displayName"] as? String) ?? "")
    }

    /// 递归遍历所有页，把每个**图标位**交给 `visit`。
    ///
    /// 结构（`formatVersion = "2"`，扁平列表）：
    /// ```
    /// [ 页0, 页1, ... ]                 页 = [ 条目, ... ]
    /// 条目 = "com.apple.xxx"            （字符串形式：只有 bundle id）
    ///      | { displayName, bundleIdentifier, iconState, ... }   （字典形式）
    ///      | { displayName, iconLists: [ 页, ... ] }             （文件夹）
    ///      | false                       （网格格式的填充格，跳过）
    /// ```
    private static func walk(pages: [Any],
                             location: String,
                             visit: (_ entry: [String: Any]?, _ bundleID: String?, _ location: String) -> Void) {
        for (pageIndex, pageAny) in pages.enumerated() {
            let pageLabel = "\(location)第 \(pageIndex + 1) 页"
            guard let items = pageAny as? [Any] else { continue }
            for item in items {
                if let id = item as? String {
                    visit(nil, id, pageLabel)
                    continue
                }
                guard let entry = item as? [String: Any] else { continue }
                if isFolder(entry) {
                    let folderName = (entry["displayName"] as? String) ?? "未命名文件夹"
                    if let sub = entry["iconLists"] as? [Any] {
                        walk(pages: sub, location: "\(pageLabel) · 文件夹「\(folderName)」", visit: visit)
                    }
                    continue
                }
                visit(entry, entry["bundleIdentifier"] as? String, pageLabel)
            }
        }
    }

    /// 递归重建：删掉签名命中 `targets` 的图标位；空页一并丢弃.
    private static func prune(pages: [Any], targets: Set<String>) -> [Any] {
        var newPages: [Any] = []
        for pageAny in pages {
            guard let items = pageAny as? [Any] else { continue }
            var newItems: [Any] = []
            for item in items {
                if let id = item as? String {
                    // 字符串形式：只有 bundle id，签名里显示名为空
                    if targets.contains(signature(bundleID: id, displayName: "")) { continue }
                    newItems.append(item)
                    continue
                }
                guard let entry = item as? [String: Any] else {
                    newItems.append(item)
                    continue
                }
                if isFolder(entry) {
                    var folder = entry
                    if let sub = entry["iconLists"] as? [Any] {
                        folder["iconLists"] = prune(pages: sub, targets: targets)
                    }
                    newItems.append(folder)
                    continue
                }
                if targets.contains(entrySignature(entry)) { continue }
                newItems.append(item)
            }
            if !newItems.isEmpty { newPages.append(newItems) }
        }
        return newPages
    }

    // MARK: - 对外：扫描

    /// 扫描顽固图标（**只读**，不改设备）.
    ///
    /// - Parameter installedBundleIDs: 设备上已安装应用的 bundle id 集合。
    ///   由调用方传入（`AppDiscovery.fetchInstalledApps()`），这样本函数只依赖注入的清单，
    ///   便于单测，也避免在扫描里再建第二条隧道.
    static func scan(installedBundleIDs: Set<String>) throws -> ScanResult {
        let data = try readState()
        let pages = try parse(data)

        var ghosts: [GhostIcon] = []
        var iconCount = 0
        var seen = Set<String>()

        walk(pages: pages, location: "") { entry, bundleID, location in
            iconCount += 1
            let displayName = (entry?["displayName"] as? String) ?? ""
            let id = bundleID ?? ""

            let kind: GhostKind?
            if !id.isEmpty {
                // 有 bundle id：设备上没装 = 顽固（白/灰图标多数是这类）
                kind = installedBundleIDs.contains(id) ? nil : .missingApp
            } else {
                // 没有 bundle id：既没名字也不是文件夹 ⇒ 空白残留
                kind = displayName.isEmpty ? .nameless : nil
            }
            guard let kind else { return }

            let sig = signature(bundleID: id, displayName: displayName)
            guard !seen.contains(sig) else { return }
            seen.insert(sig)
            ghosts.append(GhostIcon(kind: kind, bundleID: id,
                                    displayName: displayName, location: location))
        }

        return ScanResult(ghosts: ghosts, iconCount: iconCount,
                          installedCount: installedBundleIDs.count, rawState: data)
    }

    // MARK: - 对外：清理

    /// 写回布局：删掉 `ghosts` 里指定的图标，**写回前先备份原始布局**.
    ///
    /// - Parameters:
    ///   - result: `scan` 的结果（必须用**同一次**扫描拿到的 `rawState`，
    ///     否则等于拿旧布局去覆盖用户这期间做的桌面改动）
    ///   - ghosts: 用户在界面上勾选确认要删的那些
    /// - Returns: 实际删掉的条数
    @discardableResult
    static func clean(_ result: ScanResult, removing ghosts: [GhostIcon]) throws -> Int {
        guard !ghosts.isEmpty else { return 0 }
        let pages = try parse(result.rawState)
        let targets = Set(ghosts.map(\.signature))
        let pruned = prune(pages: pages, targets: targets)

        // 先备份（**在写之前** —— 写失败也能回滚）
        try saveBackup(result.rawState)

        let out = try PropertyListSerialization.data(fromPropertyList: pruned, format: .binary, options: 0)
        try writeState(out)

        let removed = result.ghosts.filter { targets.contains($0.signature) }.count
        LoginLogger.shared.log("[顽固图标] 已清理 \(removed) 个（布局 \(result.iconCount) 个图标位 → 写回 \(pruned.count) 页）",
                               category: .general)
        return removed
    }

    /// 用最近一次备份把图标位置恢复回去.
    static func restore() throws {
        guard let data = try? Data(contentsOf: latestBackupURL), !data.isEmpty else {
            throw CleanupError.noBackup
        }
        try writeState(data)
        LoginLogger.shared.log("[顽固图标] 已按备份恢复图标位置（\(data.count) 字节）", category: .general)
    }

    // MARK: - 备份

    /// 存一份原始布局：`latest.bin`（恢复用）+ 带时间戳的一份（留痕）.
    private static func saveBackup(_ data: Data) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try data.write(to: latestBackupURL, options: .atomic)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        try? data.write(to: backupDirectory.appendingPathComponent("state-\(stamp).bin"),
                        options: .atomic)
    }
}
