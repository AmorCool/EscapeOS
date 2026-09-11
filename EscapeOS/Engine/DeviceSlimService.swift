import Foundation

/// 设备瘦身 —— 爱思助手 8.0「设备瘦身」功能移植（主页新板块）.
///
/// ## 口径来源（逆向 `C:\Program Files\i4Tools8`，2026-09-11）
/// · **空间占用 7 项** = `idm_info.dll` 的 `ios_get_detailed_disk_usage` →
///   lockdown 域 `com.apple.disk_usage`（系统 = `TotalSystemCapacity`、
///   总量 = `TotalDiskCapacity`、剩余 = `AmountRestoreAvailable` 类），
///   再叠加「应用」（instproxy `StaticDiskUsage` 求和）/「照片」/「音视频」/「U盘」
///   （后三者由 AFC 实测媒体分区）。
///   真机校验（iPhone15,4 / iOS 27.0）：系统 7.85 GB、应用 23.98 GB 与爱思面板
///   **精确一致**；其余各项按「合计 = TotalDiskCapacity」口径推算「其他」。
/// · **清理分组** = 系统缓存文件 / 用户日志 / 其他临时文件 / 较大应用（> 500 MB）.
///
/// ## 可达面（免越狱，实测）
/// AFC 根 = `/var/mobile/Media`（DCIM / PhotoData / Music / Radio / 虚拟U盘 /
/// iTunes_Control / Deferred / Sync / Airlock / PublicStaging …）；
/// `house_arrest` 在 iOS 27 上 `VendContainer` 被拒（InstallationLookupFailed）、
/// `VendDocuments` 只到各 App 的 `Documents`；`/var/mobile/Library/Logs` 不可达。
/// → 因此**只清理媒体分区内可再生的缓存/缩略图**，白名单之外一律不碰。
enum DeviceSlimService {

    // MARK: - 空间占用

    /// 环形图的一段（= 爱思图例的一项）.
    struct UsageSlice: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        /// 0xRRGGBB（与爱思图例配色对齐：系统蓝 / 应用青 / 照片紫 / 音视频黄 / U盘绿 / 其他橙 / 剩余灰）
        let colorHex: UInt32
    }

    struct SpaceUsage {
        var total: Int64 = 0          // TotalDiskCapacity
        var free: Int64 = 0           // AmountRestoreAvailable（回退 AmountDataAvailable / TotalDataAvailable）
        var deviceName: String = ""   // iPhone 15
        var capacityText: String = "" // "512GB · iPhone 15"（对齐爱思副标题）
        var slices: [UsageSlice] = []

        var used: Int64 { max(0, total - free) }
        var usedPercent: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    // MARK: - 可清理项

    enum GroupKind: String, CaseIterable, Identifiable {
        case systemCache = "系统缓存文件"
        case userLog = "用户日志"
        case tempFiles = "其他临时文件"
        case bigApps = "较大应用"

        var id: String { rawValue }

        /// 副标题（对齐爱思原文案）
        var subtitle: String {
            switch self {
            case .systemCache: return "删除冗余的系统、用户"
            case .userLog: return "日志文件及过期的临时文件"
            case .tempFiles: return "删除冗余的系统、用户"
            case .bigApps: return "通过批量重装应用"
            }
        }

        /// 「较大应用」只是提示项：清理它等于卸载重装（会丢文稿与数据），
        /// 故不参与勾选与释放量统计.
        var selectable: Bool { self != .bigApps }

        var icon: String {
            switch self {
            case .systemCache: return "internaldrive.fill"
            case .userLog: return "doc.text.fill"
            case .tempFiles: return "clock.badge.exclamationmark.fill"
            case .bigApps: return "app.badge.fill"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id: String          // 删除目标用路径；较大应用用 bundleId
        let name: String
        let detail: String?
        let bytes: Int64
        let kind: GroupKind
        let deletable: Bool
    }

    struct Group: Identifiable {
        let kind: GroupKind
        let items: [Item]
        var id: String { kind.rawValue }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    struct CleanResult {
        var freed: Int64 = 0
        var deleted: Int = 0
        var failures: [String] = []
    }

    // MARK: - 白名单与常量

    /// 可再生的照片缩略图（Photos 会按需重建）. 实测 842 MiB / 10281 个文件.
    static let pathPhotoThumbnails = "/PhotoData/Thumbnails"
    /// 照片库缓存（GraphService 等）. 实测 14 MiB.
    static let pathPhotoCaches = "/PhotoData/Caches"
    /// 共享相簿的媒体缓存（CachedMedia-*）. 只删 Caches 子目录，不动同级的相簿媒体.
    static let pathSharedAlbumCaches = "/PhotoData/PhotoCloudSharingData/Caches"

    static var systemCachePaths: [(String, String)] {
        [(pathPhotoThumbnails, "照片缩略图（系统按需重建）"),
         (pathPhotoCaches, "照片库缓存"),
         (pathSharedAlbumCaches, "共享相簿媒体缓存")]
    }

    /// 临时中转目录（同步 / 恢复暂存；正常应为空，非空即残留）
    static let tempPaths: [(String, String)] = [
        ("/Deferred", "系统延迟处理暂存"),
        ("/Sync", "同步中转暂存"),
        ("/PublicStaging", "公共暂存区"),
        ("/Airlock", "空投/隔空投送暂存"),
    ]

    /// 「较大应用」阈值（爱思文案「没有超过 500M 的较大应用」）
    static let bigAppThreshold: Int64 = 500 * 1024 * 1024

    /// 空间占用里「照片」「音视频」「U盘」的 AFC 目录
    static let photoDirs = ["/DCIM", "/PhotoData"]
    static let mediaDirs = ["/Music", "/Radio", "/Recordings"]
    static let usbDir = "/虚拟U盘"

    /// 日志类文件名匹配（用户日志分组；只在媒体分区做**限深**扫描）
    private static let logPattern = ["log", "ips", "crash", "diag", "panic"]

    // MARK: - 格式化（对齐爱思：二进制单位、两位小数）

    static func formatBytes(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.2f MB", b / mb) }
        if b >= kb { return String(format: "%.2f KB", b / kb) }
        return String(format: "%.2f B", b)
    }

    // MARK: - 空间占用

    /// 读取空间占用（爱思「空间占用情况」口径）。同步阻塞 —— 调用方放后台线程.
    static func loadUsage() throws -> SpaceUsage {
        var usage = SpaceUsage()

        // 1) lockdown com.apple.disk_usage
        let du = (try? DeviceInfoService.lockdownDomainDict("com.apple.disk_usage")) ?? [:]
        func num(_ key: String) -> Int64? {
            if let n = du[key] as? Int { return Int64(n) }
            if let n = du[key] as? NSNumber { return n.int64Value }
            return nil
        }
        usage.total = num("TotalDiskCapacity") ?? num("TotalDataCapacity") ?? 0
        let system = num("TotalSystemCapacity") ?? 0
        // 剩余：爱思面板的值最贴近 AmountRestoreAvailable（含可回收的过期缓存），
        // 依次回退 AmountDataAvailable → TotalDataAvailable.
        usage.free = num("AmountRestoreAvailable")
            ?? num("AmountDataAvailable")
            ?? num("TotalDataAvailable") ?? 0

        // 2) 应用 = Σ StaticDiskUsage（实测与爱思「应用 23.98 GB」精确一致；
        //    不可用 DynamicDiskUsage —— 它含容器共享数据，在 LiveContainer
        //    场景下会重复计入 82 GB，对应爱思的「其他」而非「应用」）
        var apps: Int64 = 0
        if let list = try? FileSharingService.listAppsWithFileSharing() {
            for app in list where app.applicationType != "System" {
                apps += app.appSize ?? 0
            }
        }

        // 3) AFC 实测媒体分区（照片 / 音视频 / U盘）
        var photos: Int64 = 0, media: Int64 = 0, usb: Int64 = 0
        let svc = AFCService.shared
        try svc.batch { client in
            for dir in photoDirs { photos += measure(client: client, path: dir).bytes }
            for dir in mediaDirs { media += measure(client: client, path: dir).bytes }
            usb = measure(client: client, path: usbDir).bytes
        }

        // 4) 其他 = 总量 − 系统 − 应用 − 照片 − 音视频 − U盘 − 剩余（余量口径）
        let other = max(0, usage.total - system - apps - photos - media - usb - usage.free)

        usage.slices = [
            UsageSlice(id: "system", label: "系统", bytes: system, colorHex: 0x2F80ED),
            UsageSlice(id: "apps", label: "应用", bytes: apps, colorHex: 0x2D9CDB),
            UsageSlice(id: "photos", label: "照片", bytes: photos, colorHex: 0x9B51E0),
            UsageSlice(id: "media", label: "音视频", bytes: media, colorHex: 0xF2C94C),
            UsageSlice(id: "usb", label: "U盘", bytes: usb, colorHex: 0x27AE60),
            UsageSlice(id: "other", label: "其他", bytes: other, colorHex: 0xF2994A),
            UsageSlice(id: "free", label: "剩余", bytes: usage.free, colorHex: 0xBDBDBD),
        ]

        let machine = sysctlString("hw.machine") ?? "iPhone"
        usage.deviceName = DeviceCatalog.name(machine)
        usage.capacityText = "\(decimalCapacity(usage.total)) · \(usage.deviceName)"
        return usage
    }

    /// 512_000_000_000 B → "512GB"（对齐爱思「512GB · iPhone 15」）.
    /// `TotalDiskCapacity` 本身就是十进制标称容量（真机 = 512000000000），
    /// 故按 1e9 折算；非标称值再吸附到最接近的标称档位.
    private static func decimalCapacity(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let gb = Double(bytes) / 1_000_000_000
        if let standard = [16.0, 32, 64, 128, 256, 512, 1024, 2048].first(where: { gb <= $0 * 1.02 }) {
            return "\(Int(standard))GB"
        }
        return String(format: "%.0fGB", gb)
    }

    // MARK: - 扫描

    /// 扫描可清理项。同步阻塞 —— 调用方放后台线程。
    static func scan(progress: ((String) -> Void)? = nil) throws -> [Group] {
        var groups: [Group] = []

        progress?("正在扫描“系统缓存文件”")
        var systemItems: [Item] = []
        var logItems: [Item] = []
        var tempItems: [Item] = []
        let svc = AFCService.shared
        try svc.batch { client in
            for (path, why) in systemCachePaths {
                let m = measure(client: client, path: path)
                guard m.bytes > 0 else { continue }
                systemItems.append(Item(id: path, name: itemName(path), detail: "\(why) · \(m.files) 个文件",
                                        bytes: m.bytes, kind: .systemCache, deletable: true))
            }
            progress?("正在扫描“用户日志”")
            for hit in scanLogs(client: client) {
                logItems.append(Item(id: hit.0, name: itemName(hit.0), detail: "日志文件",
                                     bytes: hit.1, kind: .userLog, deletable: true))
            }
            progress?("正在扫描“其他临时文件”")
            for (path, why) in tempPaths {
                let m = measure(client: client, path: path)
                guard m.bytes > 0 else { continue }
                tempItems.append(Item(id: path, name: itemName(path), detail: "\(why) · \(m.files) 个文件",
                                      bytes: m.bytes, kind: .tempFiles, deletable: true))
            }
        }
        groups.append(Group(kind: .systemCache, items: systemItems))
        groups.append(Group(kind: .userLog, items: logItems))
        groups.append(Group(kind: .tempFiles, items: tempItems))

        // 较大应用（>500 MB）：只提示，勾选无意义（清理 = 卸载重装，会丢文稿与数据）
        progress?("正在扫描“较大应用”")
        var big: [Item] = []
        if let list = try? FileSharingService.listAppsWithFileSharing() {
            for app in list where app.applicationType != "System" {
                let total = (app.appSize ?? 0) + (app.docSize ?? 0)
                guard total > bigAppThreshold else { continue }
                big.append(Item(id: app.bundleId, name: app.name,
                                detail: "文稿与数据 \(formatBytes(app.docSize ?? 0))"
                                      + (app.version.isEmpty ? "" : " · v\(app.version)"),
                                bytes: total, kind: .bigApps, deletable: false))
            }
            big.sort { $0.bytes > $1.bytes }
        }
        groups.append(Group(kind: .bigApps, items: big))
        return groups
    }

    /// 路径 → 展示名（取末段）
    private static func itemName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// 媒体分区内**限深**扫描日志类文件（/var/mobile/Library/Logs 不可达，
    /// 这里只覆盖 AFC 可达范围内实际存在的日志/崩溃残留）
    private static func scanLogs(client: OpaquePointer) -> [(String, Int64)] {
        var out: [(String, Int64)] = []
        // 只扫非照片内容目录的浅层（照片目录动辄上万文件，且不含日志）
        let roots = ["/iMazing", "/iTunes_Control", "/Radio", "/Books", "/Downloads",
                     "/Espresso", "/MediaAnalysis", "/Purchases", "/AirFair"]
        var budget = 0
        for root in roots {
            var stack: [(String, Int)] = [(root, 1)]
            while let (path, depth) = stack.popLast() {
                guard budget < 5000 else { return out }
                guard let entries = try? AFCService.listDirectory(client: client, path: path) else { continue }
                for entry in entries {
                    budget += 1
                    if entry.isDirectory {
                        if depth < 2 { stack.append((entry.path, depth + 1)) }
                        continue
                    }
                    let lower = entry.name.lowercased()
                    guard logPattern.contains(where: { lower.contains($0) }) else { continue }
                    out.append((entry.path, entry.size))
                }
            }
        }
        out.sort { $0.1 > $1.1 }
        return Array(out.prefix(40))
    }

    // MARK: - 清理

    /// 删除选中项（白名单校验：只允许 systemCache / userLog / tempFiles 三类）.
    /// 同步阻塞 —— 调用方放后台线程。
    static func clean(items: [Item],
                      progress: ((Int, Int) -> Void)? = nil) throws -> CleanResult {
        var result = CleanResult()
        let targets = items.filter { $0.deletable && $0.kind != .bigApps }
        guard !targets.isEmpty else { return result }

        let svc = AFCService.shared
        try svc.batch { client in
            for (index, item) in targets.enumerated() {
                progress?(index + 1, targets.count)
                let before = measure(client: client, path: item.id).bytes
                if let ffiError = item.id.withCString({ afc_remove_path_and_contents(client, $0) }) {
                    let message = ffiError.pointee.message.map { String(cString: $0) } ?? "rc=\(ffiError.pointee.code)"
                    idevice_error_free(ffiError)
                    result.failures.append("\(item.name)：\(message)")
                    continue
                }
                // 删除后复测：仍在（或部分残留）则只计入实际消失的量
                let after = measure(client: client, path: item.id).bytes
                result.freed += max(0, before - after)
                result.deleted += 1
            }
        }
        return result
    }

    // MARK: - 辅助

    /// 递归统计目录（或单文件）字节数与文件数. 需在 `AFCService.batch` 内调用.
    static func measure(client: OpaquePointer, path: String) -> (bytes: Int64, files: Int) {
        var info = AfcFileInfo()
        let rc = path.withCString { afc_get_file_info(client, $0, &info) }
        guard rc == nil else { return (0, 0) }
        defer { afc_file_info_free(&info) }
        let isDir = info.st_ifmt.map { String(cString: $0) == "S_IFDIR" } ?? false
        if !isDir { return (Int64(info.size), 1) }

        var bytes: Int64 = 0
        var files = 0
        var stack = [path]
        while let current = stack.popLast() {
            guard let entries = try? AFCService.listDirectory(client: client, path: current) else { continue }
            for entry in entries {
                if entry.isDirectory {
                    stack.append(entry.path)
                } else {
                    bytes += entry.size
                    files += 1
                }
            }
        }
        return (bytes, files)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
