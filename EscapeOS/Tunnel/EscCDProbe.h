//
//  EscCDProbe.h
//  EscapeOS
//
//  只读诊断探针的 C 垫片：走「CoreDeviceProxy 隧道内的**第二个** RSD 握手」
//  取 CoreDevice 服务表，并端到端跑一次 app_service（cdprobe / 2026-09-19）。
//
//  ## 为什么需要这个探针
//  主页两个内置模块（`com.escapeos.locache` / `com.escapeos.wifirefresh`）与
//  「更多 → 进程管理」执行时会出现 `ServiceNotFound`（错误码 21）。
//
//  ⚠️ **成因尚未定论，本项目写过的两版归因都已作废**：①「设备未挂 DDI」；
//  ②「本仓接错了握手」。**事实（用户实测 + PC 侧交叉验证）**：`ServiceNotFound`(21)
//  是**设备侧的服务状态问题**，不是本 App 的缺陷 —— 该服务偶尔不可用，**重启手机即恢复**；
//  与 DDI、与「用哪条隧道」都无关（PC 侧标准工具 `pymobiledevice3` 拿到的 RSD 服务表
//  与我们**逐条一致**（64 条），调同一个服务**同样失败**）。**原理未知。**
//
//  仍然成立的一条（`idevice/src/services/rsd.rs:171-189`）：
//  `RsdHandshake::connect` 拿 `T::rsd_service_name()` 去 `self.services`（HashMap）查，
//  查不到直接 `Err(ServiceNotFound)`，**无回退** ⇒ 失败时重试 3 次毫无意义。
//
//  **本探针因此只回答一个工程问题**：CoreDeviceProxy 隧道内那条 RSD 握手**能不能**连上
//  app_service（即上游官方 `idevice-tools app-service` 走的那条路在本仓是否可行）。
//  上游官方 `idevice-tools app-service`（`tools/src/app_service.rs:69-85`）就是：
//      CoreDeviceProxy::connect(provider)
//      → tunnel_info().server_rsd_port
//      → create_software_tunnel()
//      → adapter.connect(rsd_port)          ← 隧道内新开一条流
//      → RsdHandshake::new(stream)          ← ★ 第二个握手，app_service 要的是它
//      → AppServiceClient::connect_rsd(&mut adapter, &mut handshake)
//  本仓 `DeviceControlService.withAppService` 用的是**第一条**（RPPairing）握手。
//  **本轮只做探针，不改 withAppService。**
//
//  ## ★ 为什么入口不是 lockdown provider（v0.3.463 真机纠正）
//  第一版探针走的是 `idevice_pairing_file_read` + `idevice_tcp_provider_new` +
//  `core_device_proxy_connect(provider)`。**真机在第一步就失败了**：
//      code=13 sub_code=0 message=UnexpectedResponse("failed to parse raw pairing file from bytes")
//  ⇒ 我们手上的 `Documents/pairingFile.plist` 是 **RpPairingFile**（RSD/无线配对格式），
//  **不是** lockdown 配对文件（旁证：`rp_pairing_file_read` 对它一直正常，RP 隧道能建）。
//  ⇒ **lockdown provider 这条路在设备侧不可用，已整体删掉。**
//
//  改用：**我们自己的 RSD 服务表里就有** `com.apple.internal.devicecompute.CoreDeviceProxy`
//  （无 `.shim.remote` 后缀，直连 TCP 端口即可），把它的端口包成 socket 就走同一条 CDTunnel。
//
//  ## 为什么必须走 C 垫片（**照 `EscBrowseApps` / `EscDDIProbe` 的先例**）
//  本 FFI 头里 `plist_t` 是 `typedef void *`（`idevice.h:317`），且这条链上
//  每一步的出参都是 opaque 结构指针。项目记忆 `.workbuddy/memory/2026-09-10.md`
//  「v0.3.279 八轮攻坚终结（C 垫片方案）」原文：
//
//      271~278 八轮 CI 里 `&x` / `withUnsafeMutablePointer` 闭包 /
//      **显式 allocate** 三种写法**全部编译失败**；改用 C 垫片后 run 453 SUCCESS。
//      教训：这个 FFI 头的 typedef void* 指针在 Swift 侧不可靠，一律走 C 垫片。
//
//  ⇒ 本垫片把**整条链（建 RPPairing 隧道 → 取 CoreDeviceProxy 端口 → CdTunnel →
//    第二个 RSD 握手 → 服务表 dump → app_service 端到端）全部关在 C 层**，
//    C 里的类型天然精确；Swift 侧只传「配对文件路径 + 目标 IP + 端口 + label」四个标量，
//    拿回**一段 UTF-8 文本报告**，零 opaque 指针参与。
//
//  ## 调用顺序（每一步失败都**如实记录并立即停止后续步骤**，不吞错、不编数字）
//    [0] 前置：解析隧道目标 IP（纯计算）
//    [1] `rp_pairing_file_read`                    —— **RP** 配对文件（**不是** `idevice_` 那个）
//    [2] `tunnel_create_rppairing`                 —— `pairing_file` 是**借用**，用完 `rp_pairing_file_free`
//    [3] `rsd_get_service_info(handshake, "com.apple.internal.devicecompute.CoreDeviceProxy", &info)`
//                                                  —— 取 `info->port`；不在表里就如实报并终止
//    [4] `idevice_new_tcp_socket(ip:info->port, ...)`  —— 直连该端口，包成 `Idevice`
//    [5] `core_device_proxy_new(idevice, &proxy)`  —— ⚠️ **消费 idevice**，此后不再 free
//    [6] `core_device_proxy_get_server_rsd_port`   —— ★ 必须在 [7] 之前（[7] 消费 proxy）
//    [7] `core_device_proxy_create_tcp_adapter`    —— ⚠️ **消费 proxy**，此后不再 free 它
//    [8] `adapter_connect(cdAdapter, rsdPort)`     —— 拿 `struct ReadWriteOpaque *`
//    [9] `rsd_handshake_new(stream)`               —— ⚠️ **消费 stream**；这就是第二个 RSD 握手
//    [10] `rsd_get_services`                       —— 只读内存结构，不建连；全量列 name/port/remoteXPC
//    [11] `app_service_connect_rsd` → `app_service_list_processes` —— ★ 端到端，报进程条数
//
//  **★ 刻意不做 `idevice_rsd_checkin`**：上游 `CoreDeviceProxy::new` 只做
//  `idevice.socket.take()` + `CdTunnel::handshake(socket)`，**没有 RSDCheckin 这一步**；
//  而且本仓 v0.3.420 正是在这里加了 `idevice_new_tcp_socket` + `idevice_rsd_checkin` 之后出的事故。
//  少做一步就少一分风险。
//
//  ## 所有权（谁分配、谁释放 —— 写清楚）
//  - **返回值**：`malloc` 出来的 UTF-8 文本（**报告本体**，不是 plist），
//    调用方用 **`free`** 释放（**不是** `plist_mem_free`，也**不是** `idevice_data_free`）。
//  - **失败**：只有当连报告缓冲都分配不出来时才返回 NULL；此时 `*out_err` 是 `malloc`
//    的 C 字符串，调用方用 **`free`** 释放。
//    ⚠️ 「某一步失败」**不等于**「返回 NULL」—— 失败原因写在报告正文里（调用方按文本展示）。
//  - **句柄**：全部在本垫片内创建并在返回前释放；被消费的四个（`pairing` 由 [2] 的
//    `rp_pairing_file_free` 归还、`idevice` 被 [5] 消费、`proxy` 被 [7] 消费、
//    `stream` 被 [9] 消费）**故意不再释放**（头文件明写 "consumed may not be used again"，
//    再 free 就是 double free）。
//
//  ## 安全约束
//  - **只读**：不挂载、不上传、不发信号、不改设备状态、不写设备文件。
//  - **一次只开一条服务连接**：本垫片只调一次 `app_service_connect_rsd`。
//    真机实证同一次运行内**第 2 个服务连接会卡死在 `adapter_connect` 上永不返回**
//    （`SSHServerService.swift:358-362`）⇒ 绝不开第二条。
//  - **必须跑在 `AFCService` 的串行队列上**（RSD 隧道并发铁律；v0.3.419/420 事故：
//    并发建隧道 ⇒ 设备端 RPPairing `attemptPairVerify` 连续 63 次零响应 ⇒
//    所有走隧道的功能一起挂）。调用方 `CDProbe.runOnce()` 负责这件事。
//  - **只由 SSH 命令 `cdprobe` 显式触发**，不挂任何 UI 路径、不自启、不放 `Task.detached`。
//

#ifndef EscCDProbe_h
#define EscCDProbe_h

#include <stdint.h>

/// 只读诊断：走 CoreDeviceProxy 隧道内的第二个 RSD 握手，dump CoreDevice 服务表，
/// 并端到端跑一次 `app_service_list_processes`。
///
/// - Parameters:
///   - pairing_path: **RP** 配对文件路径（`Documents/pairingFile.plist`，UTF-8 C 字符串）
///   - device_ip: 目标 IP（LocalDevVPN 隧道地址，如 `10.7.0.1`）
///   - rppairing_port: RPPairing 隧道端口（`49152`，与 `AFCService` / `TunnelContext` 同款）
///   - label: 连接 label（如 `EscapeSpaceCDProbe`）
///   - out_len: 出参，成功时为报告文本的字节数
///   - out_err: 出参，仅「连报告都分配不出来」时置为 `malloc` 字符串（调用方 `free`）
/// - Returns: `malloc` 的报告文本（UTF-8，**含每一步的成功/失败原文**），调用方用 `free` 释放；
///            NULL 表示连报告缓冲都没分配出来（原因见 `*out_err`）。
unsigned char *esc_cd_probe_run(const char *pairing_path,
                                const char *device_ip,
                                uint16_t rppairing_port,
                                const char *label,
                                unsigned int *out_len,
                                char **out_err);

#endif /* EscCDProbe_h */
