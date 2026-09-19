import Foundation

/// v0.3.199：电池健康数据模型 —— diagnostics_relay IORegistry/IOPMPowerSource 解析结果.
/// 字段规则移植自 iDescriptor（github.com/iDescriptor/iDescriptor）utils.rs query_battery_info.
struct BatteryHealthInfo {
    var cycleCount: Int?
    var designCapacity: Int?      // mAh（出厂设计容量）BatteryData.DesignCapacity
    var maxCapacity: Int?         // mAh（满充容量 = 当前实际满充）BatteryData.FullChargeCapacity
    var currentPercent: Int?      // 当前电量 %  BatteryData.CurrentCapacity
    var healthPercent: Int?       // 健康度 % = 满充/设计*100
    var serial: String?
    var isCharging: Bool?
    var fullyCharged: Bool?
    // v0.3.205：适配器（电源/电压）
    var adapterWatts: Int?        // W
    var adapterVoltage: Double?   // V（mV/1000）
    var adapterDescription: String?  // 连接描述（如 USB-C/无线）
    var batteryManufacturer: String? // 厂商（电池序列号前 2 位前缀查表；见 §7）
    // v0.3.286：移植爱思电池详情面板字段（IOPMPowerSource + gas gauge）
    var currentCapacityMAh: Int?     // 当前容量 mAh（BatteryData.AbsoluteCapacity）
    var voltage: Double?             // Voltage（mV → V：当前电压）
    var bootVoltage: Double?         // BootVoltage（mV → V：开机电压）
    var instantAmperage: Int?        // InstantAmperage（mA：电池电流，负=放电）
    var temperatureC: Double?        // Temperature（℃，-1/无效 → nil）
    /// v0.3.443：温度**实际取自哪个 EntryName**（`IOPMPowerSource` 或
    /// `AppleSmartBatteryPack.BatteryData`）—— 排查用，nil = 两处都没有.
    var temperatureSource: String?
    var atWarnLevel: Bool?           // AtWarnLevel（电池处于警告水平）
    var atCriticalLevel: Bool?       // AtCriticalLevel（电池处于临界水平）
    var vendorCode: String?          // 电池序列号前 3 位（F8Y 等，兼容旧表用）
    // v0.3.291：真机 iPhone15,4 / iOS 27.0 dump 实证新增
    var nominalChargeCapacity: Int?  // mAh 额定容量 BatteryData.NominalChargeCapacity
    var remainingCapacity: Int?      // mAh 剩余容量 BatteryData.RemainingCapacity
    var batteryPowerMW: Int?         // mW 电池功率 BatteryData.BatteryPower（负=放电）
    // v0.3.305：iOS 27 实测仅存的温度/临界项（用于「电池温度/警告水平」的如实展示）
    var skinTemperatureC: Int?       // ℃ 电池表皮温度
                                     // （DeadBatteryBootData.GeneralPayload.AverageBattSkinTemp，上次欠压启动记录）
    var raw: [String: Any] = [:]  // 调试用（字段缺失时可看）
}

/// v0.3.199：电池健康服务 —— diagnostics_relay IORegistry/IOPMPowerSource.
/// 非越狱、普通配对 + 解锁即可读取（iDescriptor 实证）.iOS 26/27 字段迁移已处理.
/// v0.3.205 修复：BatteryData.MaxCapacity 在某些设备返回 0-100 百分比而非 mAh
/// （iDescriptor issue #132/#133）→ 加 mAh 量级 sanity 过滤；电量改百分比；
/// 适配器电压/电源；厂商（Apple 推断）.
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
            throw makeError("未检测到配对文件.请先在「应用管理」导入配对文件（需 LocalDevVPN + 开发者模式）.")
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

    /// 读取电池健康（同步阻塞——调用方需放后台线程）.
    /// v0.3.202：机型/系统版本从 lockdown GetValue 拿（IORegistry dict 无 ProductType）.
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

    /// lockdown GetValue（domain/key 均 nil → 全字典）取 ProductType / ProductVersion.
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
        let primary: [String: Any]
        do {
            guard let node = try fetchRegistry(client: client, entryName: "IOPMPowerSource") else {
                LoginLogger.shared.log("电池：IOPMPowerSource 节点不存在（返回空）", category: .general)
                throw makeError("未返回电池数据（设备可能未解锁，或 iOS 版本不支持）")
            }
            primary = node
        } catch {
            // ★ 必须留痕：v0.3.443~v0.3.454 期间这里失败是**静默**的
            // （UI 只把错误塞进 errorText，日志里一行都没有），
            // 于是「电池读不出来」只能靠推断 battery_dump.txt 不存在来定位，代价很大。
            LoginLogger.shared.log("电池：主节点 IOPMPowerSource 查询失败：\(error.localizedDescription)", category: .general)
            throw error
        }
        // v0.3.443：iOS 27 的 `IOPMPowerSource` 里**没有** `Temperature`（真机 dump 实证），
        // 爱思 9.0 在此分支改查另一个节点 —— 反汇编实锤：
        //   idm_info.dll!ios_get_detailed_battery_info (RVA 0x13920)
        //   0x18001405c  cmp dword [rdi+0x34], 0      ; 上一步 Temperature == 0 ?
        //   0x180014064  jne 0x1800140fe              ; 非 0 → 不再查
        //   0x180014076  lea r8, "AppleSmartBatteryPack"
        //   0x1800140a9  plist_dict_get_item(node, "IORegistry")
        //   0x1800140be  plist_dict_get_item(ior, "BatteryData")
        //   0x1800140ce  plist_dict_get_item(bd, "Temperature")  → 温度
        var pack: [String: Any]? = nil
        if (intValue("Temperature", in: primary) ?? 0) <= 0 {
            // ★★ v0.3.455 修回归：这里**必须**是「失败即放弃回退」，绝不能让整个读取失败。
            //
            // v0.3.443 用的是裸 `try`。于是只要 `AppleSmartBatteryPack` 这个节点
            // 查不到（`diagnostics_relay_client_ioregistry` 的 name/class 两种形式都报错
            // ⇒ `fetchRegistry` 抛错），**整个 `query` 直接抛出** ⇒ 电池板块报「无法读取」。
            //
            // 为什么这个分支**每次都会走到**：上面那行注释已经写明「iOS 27 的
            // `IOPMPowerSource` 里没有 `Temperature`」⇒ `intValue(...) ?? 0` 恒为 0
            // ⇒ `0 <= 0` 恒真。**主数据明明已经拿到了，却被一个可选的回退节点拖死。**
            //
            // 真机实证（v0.3.452，用户报告「电池健康没法读取电池数据」）：
            //   `LoginLogs/battery_dump.txt` **不存在** —— 而它正是在本函数下一行写的，
            //   说明执行**从未走到那里**，即上面这个 `try` 抛了。
            do {
                pack = try fetchRegistry(client: client, entryName: "AppleSmartBatteryPack")
            } catch {
                LoginLogger.shared.log("电池：温度回退节点 AppleSmartBatteryPack 查询失败（不影响主数据）：\(error.localizedDescription)", category: .general)
                pack = nil
            }
        }
        // 「生产日期」定案用：把两个节点的完整 plist 落盘（只读、覆盖式、失败静默）。
        dumpBatteryRegistry(primary: primary, pack: pack)
        return parse(dict: primary, fallbackPack: pack, productType: productType, iosMajor: iosMajor)
    }

    /// 按 `EntryName` 取一个 IORegistry 节点 → 字典（节点不存在返回 nil，出错抛错）。
    ///
    /// ⚠️ `diagnostics_relay_client_ioregistry(client, current_plane, entry_name, entry_class, res)`
    /// —— `DeviceEnrichService` 把节点名放第 3 参（entry_name），本文件历史上放第 4 参（entry_class）。
    ///
    /// ★★ v0.3.455 修：**两种查法都要试，判据是「有没有拿到节点」，不是「有没有报错」。**
    ///
    /// v0.3.443 把顺序改成「先 name 查」，但退回 class 的条件写成了 `if let e`（**报错才退回**）。
    /// 真机实证（v0.3.454，2026-09-19 10:32:48）：
    /// ```
    /// 电池：IOPMPowerSource 节点不存在（返回空）
    /// 电池：主节点 IOPMPowerSource 查询失败：未返回电池数据
    /// ```
    /// ⇒ 本机上 **name 形式不报错、但返回空节点** ⇒ 退回分支根本不执行
    ///   ⇒ 主节点直接拿到 nil ⇒ **整个电池读取失败**（连温度回退都没机会跑）。
    ///   而 class 形式（本文件历史上的原始写法）本来是能取到节点的。
    ///
    /// 教训：**「没报错」不等于「拿到了」**。拿不到节点时必须继续试下一种查法。
    private static func fetchRegistry(client: OpaquePointer, entryName: String) throws -> [String: Any]? {
        // 先把两种查法都跑一遍，**只在「真的拿到节点」时才停下**。
        var firstError: UnsafeMutablePointer<IdeviceFfiError>?
        for byName in [true, false] {
            var node: plist_t?
            let e = entryName.withCString { cStr in
                byName
                    ? diagnostics_relay_client_ioregistry(client, nil, cStr, nil, &node)
                    : diagnostics_relay_client_ioregistry(client, nil, nil, cStr, &node)
            }
            if let e {
                // 这一种查法报错 ⇒ 记下第一个错误（两种都失败时用它报错），继续试下一种。
                if firstError == nil { firstError = e } else { idevice_error_free(e) }
                continue
            }
            guard let node else { continue }   // ★ 没报错但也没节点 ⇒ 继续试下一种
            if let firstError { idevice_error_free(firstError) }
            defer { plist_free(node) }
            var binPtr: UnsafeMutablePointer<CChar>?
            var binLen: UInt32 = 0
            guard plist_to_bin(node, &binPtr, &binLen) == PLIST_ERR_SUCCESS,
                  let binPtr, binLen > 0 else {
                return nil
            }
            defer { plist_mem_free(binPtr) }
            return (try? PropertyListSerialization.propertyList(
                from: Data(bytes: binPtr, count: Int(binLen)), options: [], format: nil)) as? [String: Any]
        }
        // 两种查法都没拿到节点：报错就抛错，没报错就是「这个节点确实不存在」。
        if let firstError {
            throw ffiError(firstError, fallback: "查询电池 IORegistry 失败（\(entryName)）")
        }
        return nil
    }

    /// 取整数（Int / Double / Bool / String 形态都吃），供 query 里的判定用。
    private static func intValue(_ key: String, in dict: [String: Any]) -> Int? {
        if let n = dict[key] as? Int { return n }
        if let n = dict[key] as? Double { return Int(n) }
        if let n = dict[key] as? Bool { return n ? 1 : 0 }
        if let s = dict[key] as? String { return Int(s) }
        return nil
    }

    /// v0.3.443：一次性把电池相关的两个 IORegistry 节点**完整**落盘，
    /// 用于给「生产日期到底在设备侧还是在爱思服务端」定案（本次逆向唯一没算准的一项）.
    ///
    /// - 位置：`Documents/LoginLogs/battery_dump.txt`（覆盖式，写法参照
    ///   `AirliftExploit.dumpTranscript(_:)`）；
    /// - 内容：每个节点的顶层**全部键 + 值**、`BatteryData` 的全部键 + 值，
    ///   外加一节「键名含 date / time / manufactur / produc / firstuse / factory
    ///   的键」（大小写不敏感）；
    /// - 只在成功拿到 registry 时调用（调用点见 `query`），失败静默不抛；
    /// - 只写节点 plist 本身，不含配对文件等敏感内容.
    private static func dumpBatteryRegistry(primary: [String: Any], pack: [String: Any]?) {
        /// 值 → 一行文本（Data 转 hex，嵌套 dict/array 递归展开）.
        func describe(_ value: Any) -> String {
            switch value {
            case let d as Data:
                return "<data \(d.count)B> " + d.map { String(format: "%02x", $0) }.joined()
            case let arr as [Any]:
                return "[" + arr.map { describe($0) }.joined(separator: ", ") + "]"
            case let sub as [String: Any]:
                return "{" + sub.keys.sorted().map { "\($0): \(describe(sub[$0]!))" }
                    .joined(separator: ", ") + "}"
            default:
                return "\(value)"
            }
        }

        // 键名含这些词的键 → 单独列一小节（大小写不敏感）
        let dateKeywords = ["date", "time", "manufactur", "produc", "firstuse", "factory"]
        func looksLikeDateKey(_ key: String) -> Bool {
            let lower = key.lowercased()
            return dateKeywords.contains { lower.contains($0) }
        }

        var lines: [String] = [
            "# 电池 IORegistry dump（v0.3.443 一次性排查用）",
            "# 生成时间：\(ISO8601DateFormatter().string(from: Date()))",
            ""
        ]
        var dateHits: [String] = []

        func dumpNode(_ title: String, _ dict: [String: Any]) {
            lines.append("=== \(title)（顶层 \(dict.count) 键）===")
            for key in dict.keys.sorted() {
                let text = describe(dict[key]!)
                lines.append("\(key) = \(text)")
                if looksLikeDateKey(key) { dateHits.append("[\(title)] \(key) = \(text)") }
            }
            lines.append("")
            if let bd = dict["BatteryData"] as? [String: Any] {
                lines.append("--- \(title) → BatteryData（\(bd.count) 键）---")
                for key in bd.keys.sorted() {
                    let text = describe(bd[key]!)
                    lines.append("\(key) = \(text)")
                    if looksLikeDateKey(key) {
                        dateHits.append("[\(title).BatteryData] \(key) = \(text)")
                    }
                }
                lines.append("")
            }
        }

        dumpNode("IOPMPowerSource", primary)
        if let pack { dumpNode("AppleSmartBatteryPack", pack) }

        lines.append("=== 键名含 date / time / manufactur / produc / firstuse / factory 的键 ===")
        lines.append(contentsOf: dateHits.isEmpty ? ["（无）"] : dateHits)
        lines.append("")

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoginLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("battery_dump.txt"), atomically: true, encoding: .utf8)
    }

    /// 解析 IORegistry 电池字典（字段规则来自 iDescriptor utils.rs）.
    /// v0.3.205 修复 mAh/百分比混淆 + 电流百分比 + 适配器电压/电源.
    /// v0.3.443：`fallbackPack` = `AppleSmartBatteryPack` 节点（iOS 27 温度回退，见 `query`）.
    static func parse(dict: [String: Any], fallbackPack: [String: Any]? = nil,
                      productType: String? = nil, iosMajor: Int? = nil) -> BatteryHealthInfo {
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

        // 3. 容量 —— v0.3.291 真机实证修正（iPhone15,4 / iOS 27.0 dump）：
        //    mAh 真值只在 **BatteryData** 里；顶层 AppleRawMaxCapacity /
        //    AppleRawCurrentCapacity 在 iOS 27 已不存在（爱思同环境读不到 →
        //    其「满充容量」显示 -1）。故一律以 BatteryData 为准。
        let fullCharge = num("FullChargeCapacity", in: bd) ?? num("FullChargeCapacity", in: dict)
        let nominal = num("NominalChargeCapacity", in: bd) ?? num("NominalChargeCapacity", in: dict)
        let absolute = num("AbsoluteCapacity", in: bd)
        let remaining = num("RemainingCapacity", in: bd) ?? num("TrueRemainingCapacity", in: bd)
        var maxCapacity = fullCharge ?? num("AppleRawMaxCapacity", in: dict) ?? num("MaxCapacity", in: bd)
        if let m = maxCapacity, m < 200 { maxCapacity = nil }   // 百分比形态剔除
        if maxCapacity == nil { maxCapacity = design }

        // 4. 健康度 —— v0.3.443 改爱思口径：**额定容量 / 出厂设计容量**.
        //    依据（爱思 9.0 反汇编 + 用户截图互证）：爱思「满充容量」显示 -1
        //    （即它没读到 FullChargeCapacity）却仍给出 81%，而
        //    NominalChargeCapacity / DesignCapacity = 2724 / 3329 = 81.8% ≈ 81%
        //    ⇒ 爱思「电池寿命」用的是 NominalChargeCapacity，不是 FullChargeCapacity.
        //    同时**移除**旧的 BatteryHealthBaselinePct「单调基线」闩锁：
        //    它把历史最低值锁死，本身就是「寿命不准」的直接原因；换公式后旧基线还会
        //    继续夹住新值，导致本次修复完全无效.
        //    回退链保留：nominal 取不到时用 maxCapacity（现有能力不丢）.
        var health: Int? = nil
        if let design, design > 0, let healthBase = nominal ?? maxCapacity {
            health = min(100, max(0, Int((Double(healthBase) / Double(design)) * 100)))
        }

        // 5. 当前电量 —— v0.3.291：BatteryData.CurrentCapacity 在 iOS 26/27 即百分比；
        //    老版本回退 AppleRawCurrentCapacity / AppleRawMaxCapacity 比例.
        var currentPercent: Int? = nil
        if let c = num("CurrentCapacity", in: bd), c > 0, c <= 100 {
            currentPercent = c
        } else if let cur = num("AppleRawCurrentCapacity", in: dict),
                  let rawMax = num("AppleRawMaxCapacity", in: dict), rawMax > 0 {
            currentPercent = min(100, Int(Double(cur) / Double(rawMax) * 100))
        } else if let c = num("CurrentCapacity", in: dict), c > 0, c <= 100 {
            currentPercent = c
        }

        // v0.3.443：序列号首选 `BatterySerialNumber`（与爱思 9.0 一致 —— 反汇编里它先读
        // BatterySerialNumber，为空才回退 Serial），为空时回退 `Serial`.
        let serial = (dict["BatterySerialNumber"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (dict["Serial"] as? String)
        // v0.3.291：真机 ChargerData.IsCharging 是 1/0 整数而非 Bool，补数值形态
        let isCharging: Bool? = (dict["IsCharging"] as? Bool)
            ?? num("IsCharging", in: dict).map { $0 != 0 }
            ?? (dict["ChargerData"] as? [String: Any]).flatMap { num("IsCharging", in: $0).map { v in v != 0 } }
        let fullyCharged = (dict["FullyCharged"] as? Bool)
            ?? num("FullyCharged", in: dict).map { $0 != 0 }
            ?? num("FullyCharged", in: bd).map { $0 != 0 }

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
        // 7. 厂商 —— v0.3.443 改爱思口径：电池序列号**前 2 位**前缀查表.
        //
        //    爱思 9.0 的匹配逻辑（i4Tools.exe!0x14090ff60，调用点 0x140910168）：
        //      0x14091015e  rdx = QString(entry["prefix"])
        //      0x140910163  rcx = QString(batterySerial)
        //      0x140910168  call Qt5Core!QString::startsWith   ; 命中 → 取该条目的 "cn"
        //    表来自爱思本地文件 cache/devices_table/devices_table.txt 的 `batfacotry[]`
        //    （服务端下发，本机版本 2026.09.18.01，共 13 条；已逐条抄录，未编造）.
        //    本机电池序列号 F8YH7Y22SC600006TY 前缀 F8 → 深圳欣旺达（与爱思截图逐字一致）.
        let prefix2 = serial.map { String($0.prefix(2)).uppercased() }
        let vendorCode = serial.map { String($0.prefix(3)).uppercased() }
        let manufacturer: String? = {
            if let raw = dict["Manufacturer"] as? String, !raw.isEmpty { return raw }
            if let raw = dict["BatteryManufacturer"] as? String, !raw.isEmpty { return raw }
            // 2 位前缀优先（爱思真实表）
            if let code = prefix2 {
                switch code {
                case "YW", "YV": return "无锡索尼"
                case "AE", "AF": return "东莞新能源"
                case "SB": return "三星"
                case "L5", "TP": return "天津力神"
                case "D8": return "常熟新世"
                case "FG": return "常熟新普"
                case "F5": return "惠州德赛"
                case "F8": return "深圳欣旺达"
                case "C0": return "苏州顺达"
                case "LN": return "乐金化学"
                default: break
                }
            }
            // 3 位前缀兼容回退（社区旧表，保留）
            guard let code = vendorCode else { return nil }
            switch code {
            case "F5D": return "惠州德赛"
            case "F8Y": return "深圳欣旺达"
            case "FG9": return "常熟新普"
            case "SWD": return "欣旺达"
            case "ATL": return "新能源科技(ATL)"
            case "SUN": return "索尼"
            case "LGX", "LGC": return "LG"
            case "SDI": return "三星SDI"
            default: return code
            }
        }()

        // 8. v0.3.286：爱思同款附加字段（电压/电流/温度/警告水平/当前容量 mAh）
        func volts(_ key: String) -> Double? {
            guard let mv = dbl(key, in: dict), mv > 0 else { return nil }
            return mv / 1000.0
        }
        let voltageV = volts("Voltage")
        let bootVoltageV = volts("BootVoltage")
        let amperage = num("InstantAmperage", in: dict).map { $0 > 32768 ? $0 - 65536 : $0 }
        // 温度 —— v0.3.443：`IOPMPowerSource` 缺 `Temperature`（iOS 27 真机实测）时，
        // 回退到 `AppleSmartBatteryPack` → `BatteryData.Temperature`
        // （依据见 `query` 里 0x18001405c / 0x180014076 / 0x1800140ce 的反汇编注解）.
        // 两处单位都是 1/100 ℃（3469 = 34.69 ℃）。
        // 两处都取不到 → 保持 nil（UI 显示「未知」），**不编默认值**.
        var tempC: Double? = nil
        var tempSource: String? = nil
        if let t = dbl("Temperature", in: dict), t > 0 {
            tempC = t > 200 ? t / 100.0 : t
            tempSource = "IOPMPowerSource.Temperature"
        } else if let packBD = fallbackPack?["BatteryData"] as? [String: Any],
                  let t = dbl("Temperature", in: packBD), t > 0 {
            tempC = t > 200 ? t / 100.0 : t
            tempSource = "AppleSmartBatteryPack.BatteryData.Temperature"
        }
        LoginLogger.shared.log("电池温度：\(tempC.map { String(format: "%.2f℃", $0) } ?? "未知")"
                               + "（取自 \(tempSource ?? "两处都没有")）")
        let warnLevel = dict["AtWarnLevel"] as? Bool
            ?? num("AtWarnLevel", in: dict).map { $0 != 0 }
            ?? (dict["BatteryData"] as? [String: Any]).flatMap { num("AtWarnLevel", in: $0).map { v in v != 0 } }
        let criticalLevel = dict["AtCriticalLevel"] as? Bool
            ?? num("AtCriticalLevel", in: dict).map { $0 != 0 }
        // v0.3.305：iOS 27 实测 —— 整个 IOPMPowerSource 树里唯一的温度是
        // DeadBatteryBootData.GeneralPayload.AverageBattSkinTemp（℃ 整数，上次欠压启动记录）
        let skinTemp = (dict["DeadBatteryBootData"] as? [String: Any])
            .flatMap { $0["GeneralPayload"] as? [String: Any] }
            .flatMap { num("AverageBattSkinTemp", in: $0) }
        // v0.3.291：当前容量 = BatteryData.AbsoluteCapacity（mA·h 实测值）；
        // 老版本回退 AppleRawCurrentCapacity；BatteryData.BatteryPower 为 mW 功率.
        let currentMAh = absolute
            ?? num("AppleRawCurrentCapacity", in: dict)
            ?? num("CurrentCapacity", in: dict).flatMap { c in
                (c <= 100 ? nil : c)
            }
        let powerMW = num("BatteryPower", in: bd)

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
            currentCapacityMAh: currentMAh,
            voltage: voltageV,
            bootVoltage: bootVoltageV,
            instantAmperage: amperage,
            temperatureC: tempC,
            temperatureSource: tempSource,
            atWarnLevel: warnLevel,
            atCriticalLevel: criticalLevel,
            vendorCode: vendorCode,
            nominalChargeCapacity: nominal,
            remainingCapacity: remaining,
            batteryPowerMW: powerMW,
            skinTemperatureC: skinTemp,
            raw: dict
        )
    }
}
