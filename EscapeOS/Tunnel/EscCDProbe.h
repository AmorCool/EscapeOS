//
//  EscCDProbe.h
//  EscapeOS
//
//  只读诊断探针的 C 垫片：走「CoreDeviceProxy 隧道内的**第二个** RSD 握手」
//  取 CoreDevice 服务表，并端到端跑一次 app_service（cdprobe / 2026-09-19）。
//
//  ## 为什么需要这个探针
//  主页两个内置模块（`com.escapeos.locache` / `com.escapeos.wifirefresh`）与
//  「更多 → 进程管理」执行时必现 `ServiceNotFound`（错误码 21）。
//  已核实的事实（`idevice/src/services/rsd.rs:171-189`）：
//  `RsdHandshake::connect` 拿 `T::rsd_service_name()` 去 `self.services`（HashMap）查，
//  查不到直接 `Err(ServiceNotFound)`，**无回退** ⇒ 必现，重试 3 次毫无意义。
//
//  真机实证：`tunnel_create_rppairing` 建出来的 RSD 握手包广播 64 个服务，
//  里面 `com.apple.coredevice.*` **一条都没有**（稳定复现 19 次）。
//
//  **根因（上游源码证实）**：Apple 官方通往 CoreDevice 服务的路**不是** RPPairing
//  隧道那条 RSD，而是 **CoreDeviceProxy 隧道里的第二个 RSD 握手**。上游官方
//  `idevice-tools app-service`（`tools/src/app_service.rs:69-85`）就是：
//      CoreDeviceProxy::connect(provider)
//      → tunnel_info().server_rsd_port
//      → create_software_tunnel()
//      → adapter.connect(rsd_port)          ← 隧道内新开一条流
//      → RsdHandshake::new(stream)          ← ★ 第二个握手，app_service 要的是它
//      → AppServiceClient::connect_rsd(&mut adapter, &mut handshake)
//  本仓 `DeviceControlService.withAppService` 用的是**第一条**（RPPairing）握手
//  ⇒ 必然 ServiceNotFound。**本轮只做探针，不改 withAppService。**
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
//  ⇒ 本垫片把**整条链（建 provider → CoreDeviceProxy → 第二个 RSD 握手 →
//    服务表 dump → app_service 端到端）全部关在 C 层**，C 里的类型天然精确；
//    Swift 侧只传「配对文件路径 + 目标 IP + 端口 + label」四个标量，
//    拿回**一段 UTF-8 文本报告**，零 opaque 指针参与。
//
//  ## 调用顺序（每一步失败都**如实记录并立即停止后续步骤**，不吞错、不编数字）
//    [0] 前置：解析目标 IP（纯计算）
//    [1] `idevice_pairing_file_read`      —— **lockdown** 配对文件，不是 rp_pairing_file_read
//    [2] `idevice_tcp_provider_new`       —— ⚠️ **消费 pairing**，此后永不再碰它
//    [3] `core_device_proxy_connect`      —— 之后 `idevice_provider_free(provider)`
//    [4] `core_device_proxy_get_server_rsd_port` —— ★ 必须在 [5] 之前（[5] 消费 proxy）
//    [5] `core_device_proxy_create_tcp_adapter`  —— ⚠️ **消费 proxy**，此后不再 free 它
//    [6] `adapter_connect(cdAdapter, rsdPort)`   —— 拿 `struct ReadWriteOpaque *`
//    [7] `rsd_handshake_new(stream)`             —— ⚠️ **消费 stream**
//    [8] `rsd_get_services`                      —— 只读内存结构，不建连；全量列 name/port/remoteXPC
//    [9] `app_service_connect_rsd` → `app_service_list_processes` —— ★ 端到端，报进程条数
//
//  ## 所有权（谁分配、谁释放 —— 写清楚）
//  - **返回值**：`malloc` 出来的 UTF-8 文本（**报告本体**，不是 plist），
//    调用方用 **`free`** 释放（**不是** `plist_mem_free`，也**不是** `idevice_data_free`）。
//  - **失败**：只有当连报告缓冲都分配不出来时才返回 NULL；此时 `*out_err` 是 `malloc`
//    的 C 字符串，调用方用 **`free`** 释放。
//    ⚠️ 「某一步失败」**不等于**「返回 NULL」—— 失败原因写在报告正文里（调用方按文本展示）。
//  - **句柄**：全部在本垫片内创建并在返回前释放；`pairing`（被 [2] 消费）与
//    `proxy`（被 [5] 消费）与 `stream`（被 [7] 消费）**故意不释放**（头文件明写
//    "consumed must never be used again"，再 free 就是 double free）。
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
///   - pairing_path: **lockdown** 配对文件路径（`Documents/pairingFile.plist`，UTF-8 C 字符串）
///   - device_ip: 目标 IP（LocalDevVPN 隧道地址，如 `10.7.0.1`）
///   - lockdown_port: lockdown 端口（传 `LOCKDOWN_PORT` = 62078）
///   - label: 连接 label（如 `EscapeSpaceCDProbe`）
///   - out_len: 出参，成功时为报告文本的字节数
///   - out_err: 出参，仅「连报告都分配不出来」时置为 `malloc` 字符串（调用方 `free`）
/// - Returns: `malloc` 的报告文本（UTF-8，**含每一步的成功/失败原文**），调用方用 `free` 释放；
///            NULL 表示连报告缓冲都没分配出来（原因见 `*out_err`）。
unsigned char *esc_cd_probe_run(const char *pairing_path,
                                const char *device_ip,
                                uint16_t lockdown_port,
                                const char *label,
                                unsigned int *out_len,
                                char **out_err);

#endif /* EscCDProbe_h */
