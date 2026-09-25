import Foundation

/// ▸ 只读诊断探针（svc-notfound / 2026-09-19）：回答「设备上到底挂没挂 DDI」这个**独立**问题。
///
/// ## ⚠️ 先读这段：这份探针当初是为一个**已被推翻的假设**写的
/// 它当初要验证的**主导假设**是「CoreDevice 那块是 **DDI 门控**的 —— 设备没挂 DDI ⇒
/// RSD 不广播整块 ⇒ app_service 必现 `ServiceNotFound`(21)」。**该假设已作废。**
/// 后来写过的第三版归因「接错隧道」**也作废**（与 PC 侧 `pymobiledevice3` 的交叉验证矛盾）。
///
/// **事实（用户实测 + PC 侧交叉验证）**：`ServiceNotFound`(21) 是**设备侧的服务状态问题**，
/// **不是本 App 的缺陷** —— 该服务在设备侧**偶尔**不可用，**重启手机即恢复**（用户实测；
/// 同类工具也这么处理）。**与 DDI 无关，也与「用哪条隧道」无关**：PC 侧标准工具
/// `pymobiledevice3` 拿到的 RSD 服务表与我们**逐条一致**（64 条），调同一个服务**同样失败**。
/// **原理未知** —— 不要再往这个方向补推测。
///
/// ## ▸ `ddiprobe` 现在还有没有用？有。
/// 它回答的是「**DDI 挂没挂**」这个**独立**问题（设备侧已挂载的开发者镜像列表），
/// 与 `ServiceNotFound` 无关 —— 所以**本文件与 `ddiprobe` 命令都保留**。
/// 只是**不要再拿它的结果去解释 `ServiceNotFound`**。
///
/// ## 探针当初的依据（保留作历史记录，**归因部分已作废**）
/// 主页两个内置模块（`com.escapeos.locache` / `com.escapeos.wifirefresh`，都是 `type: "signal"`）
/// 执行时会出现 `ServiceNotFound`（错误码 21）。仍然成立的一条：
/// - `RsdHandshake::connect` 是纯 `HashMap` 查表，查不到直接 `Err(ServiceNotFound)`，无回退
///   （`idevice/src/services/rsd.rs:171-189`）⇒ 失败时**重试 3 次毫无意义**；
///
/// 已作废、**不要再引用**的两条（保留作历史）：
/// - ~~真机 19 次 RSD dump 里整块 `com.apple.coredevice.*` 都不在 ⇒ 缺 CoreDevice 那一块~~；
/// - ~~主导假设：CoreDevice 那块是 DDI 门控的；旁证 pymobiledevice3 #1744 /
///   `remote_service_discovery.py:462-465` 的报错文案 / StikDebug 把挂 DDI 当前置条件~~；
/// - ~~第三版：本仓接错了握手（CoreDevice 族只在 CoreDeviceProxy 隧道内的第二个 RSD 握手上）~~。
///
/// **本探针只回答一个问题：设备上已挂载的开发者镜像列表是空还是非空。**
///
/// ## ▸ 为什么走 C 垫片（`EscDDIProbe.c`），而不是 Swift 直调 FFI
/// 本探针要用的两个函数的出参都是 **opaque 指针数组**形状：
///   · `image_mounter_connect_rsd(..., struct ImageMounterHandle **client)`
///   · `image_mounter_copy_devices(..., plist_t **devices, size_t *devices_len)`
/// 而本 FFI 头里 `plist_t` 是 `typedef void *`（`idevice.h:317`），它的指针出参在
/// Clang Importer 下类型推断**不可靠**。项目记忆 `.workbuddy/memory/2026-09-10.md`
/// 「v0.3.279 八轮攻坚终结（C 垫片方案）」原文：
///   > 271~278 八轮 CI 里 `&x` / `withUnsafeMutablePointer` 闭包 /
///   > **显式 allocate** 三种写法**全部编译失败**；改用 C 垫片后 run 453 SUCCESS。
///   > 教训：这个 FFI 头的 typedef void* 指针在 Swift 侧不可靠，一律走 C 垫片。
/// ⇒ 本探针照 `EscBrowseApps.c` 的先例：**调用 + 遍历 + 序列化全在 C 层**，
/// Swift 侧只传两个 `OpaquePointer`、拿回 bplist 字节，**零 `plist_t` / 零 opaque 指针出参**。
///
/// ## 安全约束（必须遵守）
/// 依据：v0.3.419/420 的真机事故 ——
/// v0.3.419/420 在自检/detached 路径对 RSD 服务做 `adapter_connect` + `rsd_checkin`，
/// 导致设备端 RPPairing `attemptPairVerify` **此后全部零响应**（连续 63 次超时），
/// **所有走 RSD 隧道的功能一起失效**。
///
/// 1. **跑在 `AFCService` 的同一条串行队列上**（`AFCService.runExclusively`）——
///    不自建队列，避免与 AFC / 进程管理 / 设备控制并发建隧道互相抢占。
/// 2. **只建一条服务连接**，用完立即 `free` —— 现已**落在 C 垫片内部**
///    （`esc_ddi_copy_devices` 里 `image_mounter_connect_rsd` → 用完 → `image_mounter_free`），
///    Swift 侧连句柄都拿不到，从结构上杜绝"忘记释放"。
///    真机实证：同一次运行内**第 2 个服务连接会卡死在 `adapter_connect` 上永不返回**
///    （`SSHServerService.swift:358-362`）⇒ 本探针**绝不开第二条服务连接**。
///    `rsd_get_services` 只是读已建隧道里的**内存结构**，不建连。
/// 3. **只读**：不挂载、不发信号、不改任何设备状态。
/// 4. **只由 SSH 命令 `ddiprobe` 显式触发**，不挂任何 UI 路径、不自启、不放 `Task.detached`。
///
/// ## 所有权
/// - 垫片返回的 bplist 字节由 libplist 分配 ⇒ 本文件用 **`plist_mem_free`** 释放。
/// - 垫片返回的失败原因字符串由 `malloc` 分配 ⇒ 本文件用 **`free`** 释放。
/// - `image_mounter_copy_devices` 的**外层指针数组**在 C 层**故意泄漏**
///   （`count × 8` 字节；本库没有该来源的释放函数）—— 细节见 `EscDDIProbe.c` 第 5 步注释。
///   一次性只读探针，**可接受**。
enum DDIMountProbe {

    /// 落盘文件名（`Documents/LoginLogs/ddi_probe.txt`，覆盖式）
    static let logFileName = "ddi_probe.txt"

    /// 强制跑一次（忽略任何单飞标记）。返回完整记录，同时落盘。
    /// 调用方必须是 SSH 命令处理路径（见 `SSHServerService` 的 `ddiprobe`）。
    @discardableResult
    static func runOnce() -> String {
        var lines: [String] = []
        let stamp = ISO8601DateFormatter().string(from: Date())
        lines.append("=== DDI 挂载只读探针 @ \(stamp) ===")
        lines.append("目的：判定设备上是否已挂载 Developer Disk Image（DDI）")
        // 依据行（用户可见输出）：只写事实与恢复办法，**不写任何成因推测**。
        lines.append("依据：ServiceNotFound(21) 是设备侧的服务状态问题，不是本 App 的缺陷；该服务偶尔不可用，重启手机即恢复（用户实测）。与 DDI、与「用哪条隧道」均无关")
        lines.append("")

        do {
            // ▸ 唯一入口：整段跑在 AFCService 的串行队列上（RSD 隧道并发铁律）
            let body = try AFCService.shared.runExclusively { try probeBody() }
            lines.append(contentsOf: body)
        } catch {
            lines.append("❌ 探针失败：\(error.localizedDescription)")
        }

        let text = lines.joined(separator: "\n")
        write(text)
        return text
    }

    // MARK: - 探针主体（**已在本串行队列内**）

    private static func probeBody() throws -> [String] {
        var out: [String] = []

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pairingPath = docs.appendingPathComponent("pairingFile.plist").path

        out.append("[0] 前置")
        out.append("  · 配对文件：\(FileManager.default.fileExists(atPath: pairingPath) ? "存在" : "缺失")  \(pairingPath)")
        out.append("  · LocalDevVPN targetIP=\(LocalDevVPN.targetIP) isConnected=\(LocalDevVPN.isConnected)")
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            out.append("")
            out.append("结论：未导入配对文件，探针终止（无法建隧道）。")
            return out
        }

        // 1) 建隧道（本探针唯一一次建隧道）
        out.append("")
        out.append("[1] 建 RSD 隧道 tunnel_create_rppairing（EscapeSpaceDevice）")
        var tunnel = TunnelHandles()
        defer { tunnel.free() }
        do {
            try buildTunnel(into: &tunnel, pairingPath: pairingPath)
            out.append("  · 隧道 OK（adapter + handshake 均已就绪）")
        } catch {
            out.append("  ❌ 建隧道失败：\(error.localizedDescription)")
            out.append("")
            out.append("结论：隧道没建起来 —— 本次探针无法回答 DDI 问题（先解决 LocalDevVPN / 配对文件）。")
            return out
        }
        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            out.append("  ❌ 隧道句柄为空")
            return out
        }

        // 2) 读 RSD 服务表（**只读内存结构，不建连**）
        //    ⚠️ 下面 dump 出来的「coredevice 整块不在表里」**不解释 `ServiceNotFound`** ——
        //       既不是 DDI 造成的，也不是「接错隧道」造成的（两版归因都已作废）。
        //       `dumpServiceTable` 的判据 A/B/C 仍有参考价值（判据 C 是「DDI 挂没挂」的旁证），
        //       但**不要把它读成 `ServiceNotFound` 的解释**。
        out.append("")
        out.append("[2] RSD 服务表（rsd_get_services，只读内存，不建连）")
        dumpServiceTable(handshake, into: &out)

        // 3) ▸ 唯一一条服务连接 + 唯一判据 —— **全部在 C 垫片里完成**
        out.append("")
        out.append("[3] ▸ 判据 esc_ddi_copy_devices（C 垫片）")
        out.append("    垫片内部：image_mounter_connect_rsd → copy_devices → image_mounter_free")
        //
        // ⚠️ 这里**刻意不出现任何 FFI 指针** —— 理由见本文件头注释「为什么走 C 垫片」。
        //    一句话：`ImageMounterHandle **` / `plist_t **` 这两个 opaque 指针数组出参
        //    在 Swift 侧烧掉过八轮 CI（271~278），垫片是本仓唯一被验证过的路（run 453 SUCCESS）。
        var byteLen: UInt32 = 0
        var errorCStr: UnsafeMutablePointer<CChar>?
        let bytes = esc_ddi_copy_devices(adapter, handshake, &byteLen, &errorCStr)

        guard let bytes else {
            let message = errorCStr.map { String(cString: $0) } ?? "（垫片未给出原因）"
            if let errorCStr { free(errorCStr) }        // 垫片的失败字符串是 malloc 的 ⇒ free
            out.append("  ❌ 垫片失败：\(message)")
            out.append("")
            out.append("结论：连不上 / 查询失败 ⇒ 无法判定 DDI 挂载状态。")
            return out
        }
        defer { plist_mem_free(bytes) }                 // bplist 字节由 libplist 分配 ⇒ plist_mem_free
        out.append("  · 返回 bplist 字节数 = \(byteLen)")

        // ▸ 解析失败必须与「列表为空」区分开 —— 否则会把「查不了」误报成「没挂 DDI」。
        guard let images = parsePlistArray(bytes, byteLen) else {
            out.append("  ❌ 垫片返回的字节解析失败（length=\(byteLen)）")
            out.append("")
            out.append("结论：解析失败 ⇒ DDI 挂载状态仍未定（既不能确认也不能否证假设）。")
            return out
        }

        // 4) ▸ 判据：列表空 / 非空
        out.append("")
        out.append("[4] ▸ 判据：设备上已挂载的开发者镜像列表（**空 = 未挂 DDI**）")
        out.append("  · 已挂载开发者镜像数量 = \(images.count)")
        for (index, image) in images.enumerated() {
            out.append("  --- 镜像 #\(index + 1) plist 原文 ---")
            for line in xmlOfDictionary(image).components(separatedBy: "\n") where !line.isEmpty {
                out.append("  \(line)")
            }
        }

        out.append("")
        out.append("[5] 结论")
        // ⚠️ 下面两个分支只报告「设备挂没挂 DDI」这个**独立事实**。
        //    不要再把它当成 `ServiceNotFound` 的解释（DDI 与「接错隧道」两版归因都已作废），
        //    **也不要照着它去挂 DDI**。
        if !images.isEmpty {
            out.append("  ⇒ **已挂 DDI**：设备侧已挂载开发者镜像（与 ServiceNotFound 无关）。")
            out.append("     ServiceNotFound(21) 是设备侧服务状态问题，该服务偶尔不可用，")
            out.append("     重启手机即恢复（用户实测）——与本探针报告的 DDI 状态没有关系。")
        } else {
            out.append("  ⇒ **未挂 DDI**（列表为空）：设备侧未挂载开发者镜像（与 ServiceNotFound 无关）。")
            out.append("     ServiceNotFound(21) 是设备侧服务状态问题，该服务偶尔不可用，")
            out.append("     重启手机即恢复（用户实测）——与本探针报告的 DDI 状态没有关系。")
        }
        return out
    }

    // MARK: - 隧道（与 AFCService / DeviceControlService 同款写法）

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
            if let adapter { adapter_free(adapter); self.adapter = nil }
        }
    }

    /// `10.7.0.1:49152`（RPPairing）+ 3 次退避重试 —— 与 `AFCService.createTunnel` 完全同款。
    private static func buildTunnel(into tunnel: inout TunnelHandles, pairingPath: String) throws {
        var pairingFile: OpaquePointer?
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            let message = ffiError.pointee.message.map { String(cString: $0) } ?? ""
            let code = Int(ffiError.pointee.code)
            idevice_error_free(ffiError)
            throw probeError("读取配对文件失败 code=\(code) \(message)")
        }
        guard let pairingFile else { throw probeError("读取配对文件失败") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian
        let deviceIP = LocalDevVPN.targetIP
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw probeError("隧道 IP 无效：\(deviceIP)")
        }

        var lastError: NSError?
        for attempt in 0..<3 {
            var candidate = TunnelHandles()
            let ffiError = "EscapeSpaceDevice".withCString { hn in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        tunnel_create_rppairing(
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hn,
                            pairingFile,
                            nil,
                            nil,
                            &candidate.adapter,
                            &candidate.handshake
                        )
                    }
                }
            }
            if let ffiError {
                let message = ffiError.pointee.message.map { String(cString: $0) } ?? ""
                let code = Int(ffiError.pointee.code)
                idevice_error_free(ffiError)
                lastError = probeError("code=\(code) \(message)")
            } else if candidate.adapter != nil, candidate.handshake != nil {
                tunnel = candidate
                return
            } else {
                var incomplete = candidate
                incomplete.free()
                lastError = probeError("返回空句柄")
            }
            if attempt < 2 { usleep(useconds_t(300_000 * (attempt + 1))) }
        }
        throw lastError ?? probeError("创建开发者隧道失败")
    }

    // MARK: - 服务表（只读内存，不建连）

    /// dump RSD 服务表，并**显式点名**三条与本问题直接相关的判据。
    private static func dumpServiceTable(_ handshake: OpaquePointer, into out: inout [String]) {
        var servicesArray: UnsafeMutablePointer<CRsdServiceArray>?
        if let ffiError = rsd_get_services(handshake, &servicesArray) {
            let message = ffiError.pointee.message.map { String(cString: $0) } ?? ""
            let code = Int(ffiError.pointee.code)
            idevice_error_free(ffiError)
            out.append("  ❌ rsd_get_services 失败 code=\(code) \(message)")
            return
        }
        guard let servicesArray else {
            out.append("  ❌ rsd_get_services 返回空")
            return
        }
        defer { rsd_free_services(servicesArray) }

        let total = Int(servicesArray.pointee.count)
        var names: [String] = []
        if let list = servicesArray.pointee.services {
            for index in 0..<total {
                if let namePtr = list[index].name {
                    names.append(String(cString: namePtr))
                }
            }
        }
        out.append("  · 服务总数 = \(total)（隧道内受信 RSD；直连 untrusted RSD 只有 7 个）")

        // 判据 A：本探针要连的服务在不在
        let mounterName = "com.apple.mobile.mobile_image_mounter.shim.remote"
        out.append("  · [判据 A] \(mounterName) → \(names.contains(mounterName) ? "在表里" : "❌ 不在表里")")

        // 判据 B：CoreDevice 整块（当初以为它是本次问题的主角，**该归因已作废**）
        let coreDevice = names.filter { $0.hasPrefix("com.apple.coredevice") }.sorted()
        out.append("  · [判据 B] com.apple.coredevice.* 共 \(coreDevice.count) 条"
                   + (coreDevice.isEmpty ? "（整块不在；这与 ServiceNotFound 无关）" : "："))
        for name in coreDevice { out.append("      - \(name)") }

        // 判据 C：DDI 已挂的两个外部标志（pymobiledevice3 #1744 用的判据）
        //   仅用于回答「DDI 挂没挂」这个独立问题，**与 ServiceNotFound 无关**。
        for marker in ["com.apple.dt.testmanagerd.remote", "com.apple.dt.ViewHierarchyAgent.remote"] {
            out.append("  · [判据 C] \(marker) → \(names.contains(marker) ? "在表里（旁证：DDI 已挂）" : "不在表里")")
        }

        // 附：全部服务名（便于与 `_tmp_services.txt` 逐条比对）
        out.append("  · 全表（\(names.count) 条）：")
        for name in names.sorted() { out.append("      \(name)") }
    }

    // MARK: - 工具（**纯 Foundation，不碰 plist_t**）

    /// 把垫片返回的 bplist 字节解析成「镜像字典」数组。
    ///
    /// - Returns: 解析成功返回数组（**空数组 = 设备未挂 DDI**）；解析失败返回 `nil`。
    ///   ⚠️ 失败与「空」**必须区分**，否则会把「查不了」误报成「没挂 DDI」。
    private static func parsePlistArray(_ bytes: UnsafeMutablePointer<UInt8>,
                                        _ length: UInt32) -> [[String: Any]]? {
        guard length > 0 else { return nil }
        let data = Data(bytes: bytes, count: Int(length))
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let array = parsed as? [[String: Any]] else {
            return nil
        }
        return array
    }

    /// 把一个镜像字典序列化成可读 XML（纯 Foundation，不碰 plist_t）。
    private static func xmlOfDictionary(_ dict: [String: Any]) -> String {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                             format: .xml, options: 0),
              let text = String(data: data, encoding: .utf8) else {
            return "（序列化失败）"
        }
        return text
    }

    private static func probeError(_ message: String) -> NSError {
        NSError(domain: "DDIMountProbe", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func write(_ text: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoginLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(logFileName),
                        atomically: true, encoding: .utf8)
    }
}
