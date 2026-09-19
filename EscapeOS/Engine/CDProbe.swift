import Foundation

/// ★ 只读诊断探针（svc-notfound / 2026-09-19）：走一遍 CoreDeviceProxy 隧道内的
/// 「第二个 RSD 握手」，看 `com.apple.coredevice.appservice` 能不能连上。
///
/// ## 为什么要这个探针
/// 主页两个内置模块（`com.escapeos.locache` / `com.escapeos.wifirefresh`，`type: "signal"`）
/// 与「更多 → 进程管理」执行时会出现 `ServiceNotFound`（错误码 21）。
///
/// ⚠️ **成因尚未定论，本项目写过的两版归因都已作废**：①「设备未挂 DDI」；
/// ②「本仓接错了握手（CoreDevice 族只在 CoreDeviceProxy 隧道的第二个 RSD 握手上）」。
/// **事实（用户实测 + PC 侧交叉验证）**：`ServiceNotFound`(21) 是**设备侧的服务状态问题**，
/// 不是本 App 的缺陷 —— 该服务偶尔不可用，**重启手机即恢复**；与 DDI、与「用哪条隧道」
/// 都无关（PC 侧标准工具 `pymobiledevice3` 拿到的 RSD 服务表与我们**逐条一致**（64 条），
/// 调同一个服务**同样失败**）。**原理未知。**
///
/// 仍然成立的一条：`RsdHandshake::connect` 拿 `T::rsd_service_name()` 去 `self.services`
/// （`HashMap`）查，查不到直接 `Err(IdeviceError::ServiceNotFound)`，**无回退**
/// （`idevice/src/services/rsd.rs:171-189`）⇒ 失败时**重试 3 次毫无意义**。
///
/// **本探针因此只回答一个工程问题**：CoreDeviceProxy 隧道内那条 RSD 握手**能不能**连上
/// app_service（即上游官方 `idevice-tools app-service` 走的那条路在本仓是否可行）。
/// 上游官方 `idevice-tools app-service`（`tools/src/app_service.rs:69-85`）就是：
/// ```rust
/// let proxy = CoreDeviceProxy::connect(&*provider).await.expect("no core proxy");
/// let rsd_port = proxy.tunnel_info().server_rsd_port;
/// let adapter = proxy.create_software_tunnel().expect("no software tunnel");
/// let mut adapter = adapter.to_async_handle();
/// let stream = adapter.connect(rsd_port).await.expect("no RSD connect");
/// let mut handshake = RsdHandshake::new(stream).await.unwrap();   // ← 第二个握手
/// let mut asc = AppServiceClient::connect_rsd(&mut adapter, &mut handshake).await;
/// ```
/// 本仓 `DeviceControlService.withAppService` 用的是**第一条**（RPPairing）握手。
/// **本轮只做探针，不动 `withAppService`。**
///
/// ## ★ 入口已按 v0.3.463 真机结果换掉（**重要**）
/// 第一版探针走 `idevice_pairing_file_read` + `idevice_tcp_provider_new` +
/// `core_device_proxy_connect(provider)`。**真机在第一步就失败**：
/// ```
/// [1] idevice_pairing_file_read
///   ❌ 失败：code=13 sub_code=0 message=UnexpectedResponse("failed to parse raw pairing file from bytes")
/// ```
/// ⇒ `Documents/pairingFile.plist` 是 **RpPairingFile**（RSD/无线配对格式），
/// **不是** lockdown 配对文件（旁证：`rp_pairing_file_read` 对它一直正常 —— RP 隧道能建、
/// airlift 报「配对文件 OK」）。⇒ **lockdown provider 这条路在设备侧不可用，已整体删掉。**
///
/// 改用：**我们自己的 RSD 服务表里就有** `com.apple.internal.devicecompute.CoreDeviceProxy`
/// （真机 64 条服务之一，**无** `.shim.remote` 后缀，直连 TCP 端口即可），
/// 把它的端口包成 socket 就走同一条 CDTunnel。
///
/// ## 实际调用链（全部在 `EscCDProbe.c` 里）
/// `rp_pairing_file_read` → `tunnel_create_rppairing`(10.7.0.1:49152) →
/// `rsd_get_service_info("com.apple.internal.devicecompute.CoreDeviceProxy")` →
/// `idevice_new_tcp_socket(10.7.0.1:info->port)` → `core_device_proxy_new` →
/// `core_device_proxy_get_server_rsd_port` → `core_device_proxy_create_tcp_adapter` →
/// `adapter_connect` → **`rsd_handshake_new`（第二个握手）** → `rsd_get_services` →
/// `app_service_connect_rsd` → `app_service_list_processes`。
/// **刻意不做 `idevice_rsd_checkin`**（上游 `CoreDeviceProxy::new` 没有这一步；
/// 本仓 v0.3.420 正是在那里加 checkin 之后出的配对事故）。
///
/// ## ★ 为什么走 C 垫片（`EscCDProbe.c`），而不是 Swift 直调 FFI
/// 本 FFI 头里 `plist_t` 是 `typedef void *`（`idevice.h:317`），且这条链每一步的出参
/// 都是 opaque 结构指针。项目记忆 `.workbuddy/memory/2026-09-10.md`
/// 「v0.3.279 八轮攻坚终结（C 垫片方案）」原文：
///   > 271~278 八轮 CI 里 `&x` / `withUnsafeMutablePointer` 闭包 /
///   > **显式 allocate** 三种写法**全部编译失败**；改用 C 垫片后 run 453 SUCCESS。
///   > 教训：这个 FFI 头的 typedef void* 指针在 Swift 侧不可靠，一律走 C 垫片。
/// ⇒ 本探针照 `EscDDIProbe.c` / `EscBrowseApps.c` 的先例：**整条链（建 provider →
/// CoreDeviceProxy → 第二个 RSD 握手 → 服务表 dump → app_service 端到端）全在 C 层**，
/// Swift 侧只传「配对文件路径 + 目标 IP + 端口 + label」四个标量、拿回文本，**零 opaque 指针**。
///
/// ## 安全约束（必须遵守）
/// 1. **跑在 `AFCService` 的同一条串行队列上**（`AFCService.runExclusively`）——
///    不自建队列。依据：RSD 隧道并发铁律；v0.3.419/420 真机事故 —— 并发建隧道 ⇒
///    设备端 RPPairing `attemptPairVerify` 连续 63 次零响应 ⇒ **所有走隧道的功能一起挂**。
/// 2. **只开一条服务连接**（`app_service_connect_rsd` 一次）。真机实证：同一次运行内
///    第 2 个服务连接会卡死在 `adapter_connect` 上永不返回（`SSHServerService.swift:358-362`）。
/// 3. **只读**：不挂载、不上传、不发信号、不改设备状态（除结果 txt 落盘）。
/// 4. **只由 SSH 命令 `cdprobe` 显式触发**，不挂任何 UI 路径、不自启、不放 `Task.detached`。
///
/// ## 所有权
/// - 垫片返回的报告文本由 `malloc` 分配 ⇒ 本文件用 **`free`** 释放
///   （**不是** `plist_mem_free` —— 那不是 plist，只是纯文本）。
/// - 垫片的 `out_err` 也是 `malloc` ⇒ 本文件用 **`free`** 释放。
/// - 「某一步失败」**不等于**垫片返回 NULL：失败原文写在报告正文里，本文件照原样展示。
enum CDProbe {

    /// 落盘文件名（`Documents/LoginLogs/cd_probe.txt`，覆盖式）
    static let logFileName = "cd_probe.txt"

    /// 连接 label（与 `TunnelContext.m` 的 label 用法同源，仅用于设备侧识别）
    private static let connectLabel = "EscapeSpaceCDProbe"

    /// RPPairing 隧道端口（`10.7.0.1:49152`）。
    /// 与 `AFCService` / `DeviceControlService` / `DDIMountProbe` / `TunnelContext.m` 同款 ——
    /// **不是** lockdown 的 62078（那条路要 lockdown 配对文件，我们手上没有）。
    private static let rppairingPort: UInt16 = 49152

    /// 强制跑一次。返回完整记录，同时落盘 + 记一行摘要到登录日志。
    /// 调用方必须是 SSH 命令处理路径（见 `SSHServerService` 的 `cdprobe`）。
    @discardableResult
    static func runOnce() -> String {
        var lines: [String] = []
        let stamp = ISO8601DateFormatter().string(from: Date())
        lines.append("=== CoreDeviceProxy 隧道内第二 RSD 握手只读探针 @ \(stamp) ===")
        lines.append("目的：判定 com.apple.coredevice.appservice 是否只在 CoreDeviceProxy 隧道内的第二个 RSD 握手里广播")
        lines.append("对照：RPPairing 隧道那条握手 19 次真机 dump 里 com.apple.coredevice.* 整块 0 条")
        lines.append("")

        do {
            // ★ 唯一入口：整段跑在 AFCService 的串行队列上（RSD 隧道并发铁律）
            lines.append(try AFCService.shared.runExclusively { probeBody() })
        } catch {
            lines.append("❌ 探针失败：\(error.localizedDescription)")
        }

        let text = lines.joined(separator: "\n")
        write(text)
        LoginLogger.shared.log(summary(from: text), category: .general)
        return text
    }

    // MARK: - 探针主体（**已在本串行队列内**）

    private static func probeBody() -> String {
        var out: [String] = []

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pairingPath = docs.appendingPathComponent("pairingFile.plist").path

        out.append("[前置]")
        out.append("  · 配对文件：\(FileManager.default.fileExists(atPath: pairingPath) ? "存在" : "缺失")  \(pairingPath)")
        out.append("  · 目标 IP = \(LocalDevVPN.targetIP)（与 TunnelContext.m 的 _targetIP 同源：NSUserDefaults TunnelDeviceIP 可覆盖）")
        out.append("  · LocalDevVPN isConnected=\(LocalDevVPN.isConnected)")
        out.append("")
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            out.append("结论：未导入配对文件，探针终止（无法建 provider）。")
            return out.joined(separator: "\n")
        }

        // ★ 整条 FFI 链关在 C 垫片里 —— 理由见本文件头注释「为什么走 C 垫片」。
        //    一句话：这个 FFI 头的 typedef void* 指针在 Swift 侧不可靠，
        //    `EscCDProbe.c` 是本仓唯一被验证过的形态（v0.3.279 八轮 CI 的结论）。
        var byteLen: UInt32 = 0
        var errorCStr: UnsafeMutablePointer<CChar>?
        let bytes = pairingPath.withCString { path in
            LocalDevVPN.targetIP.withCString { ip in
                connectLabel.withCString { label in
                    esc_cd_probe_run(path, ip, rppairingPort, label, &byteLen, &errorCStr)
                }
            }
        }

        guard let bytes else {
            let message = errorCStr.map { String(cString: $0) } ?? "（垫片未给出原因）"
            if let errorCStr { free(errorCStr) }      // 垫片的失败字符串是 malloc 的 ⇒ free
            out.append("❌ 垫片未能产出报告：\(message)")
            return out.joined(separator: "\n")
        }
        defer { free(bytes) }                          // 报告文本是 malloc 的 ⇒ free（不是 plist_mem_free）

        out.append(String(decoding: UnsafeBufferPointer(start: bytes, count: Int(byteLen)),
                          as: UTF8.self))
        return out.joined(separator: "\n")
    }

    // MARK: - 摘要（登录日志**只记一行**，全文在落盘文件里）

    /// 从报告里挑出判据行，拼成**一行**摘要。
    /// 依据：CORE.md「日志写入时会被 truncate() 截断」⇒ 长内容必须独立落盘，
    /// 日志里只留可一眼判断的结论。
    private static func summary(from text: String) -> String {
        let markers = [
            "com.apple.coredevice.appservice →",
            "com.apple.coredevice.* 共",
            "★ 返回进程条数 =",
            "❌ app_service_connect_rsd",
            "❌ app_service_list_processes",
            "❌ rsd_get_services",
            "❌ rsd_handshake_new",
            "❌ adapter_connect",
            "❌ core_device_proxy",
            "❌ idevice_new_tcp_socket",
            "❌ rsd_get_service_info",
            "❌ tunnel_create_rppairing",
            "❌ rp_pairing_file_read",
        ]
        var picked: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if markers.contains(where: { trimmed.contains($0) }) {
                picked.append(trimmed)
            }
        }
        let joined = picked.joined(separator: " | ")
        return "cdprobe：" + (joined.isEmpty ? "报告已生成，未命中判据行（全文见 LoginLogs/cd_probe.txt）" : joined)
    }

    private static func write(_ text: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoginLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(logFileName),
                        atomically: true, encoding: .utf8)
    }
}
