//
//  EscDDIProbe.h
//  EscapeOS
//
//  只读 DDI（Developer Disk Image）探针的 C 垫片（svc-notfound / 2026-09-19）。
//
//  背景（**照 `EscBrowseApps` 的先例，不是自己发明的形状**）：
//  本 FFI 头里 `plist_t` 是 `typedef void *`（`idevice.h:317`），它的指针出参在
//  Clang Importer 下类型推断**不可靠**。项目记忆 `.workbuddy/memory/2026-09-10.md`
//  「v0.3.279 八轮攻坚终结（C 垫片方案）」原文：
//
//      271~278 八轮 CI 里 `&x` / `withUnsafeMutablePointer` 闭包 /
//      **显式 allocate** 三种写法**全部编译失败**；改用 C 垫片后 run 453 SUCCESS。
//      教训：这个 FFI 头的 typedef void* 指针在 Swift 侧不可靠，一律走 C 垫片。
//
//  本探针要用的两个函数出参都是 opaque 指针数组形状，正是那个雷区：
//      · `image_mounter_connect_rsd(..., struct ImageMounterHandle **client)`
//      · `image_mounter_copy_devices(..., plist_t **devices, size_t *devices_len)`
//  ⇒ 两者**全部关在 C 层**，Swift 侧**零 `plist_t` / 零 opaque 指针出参**。
//
//  ## 所有权（谁分配、谁释放 —— 写清楚）
//  - **成功**：返回值是 libplist 分配的 binary plist 字节（由 `plist_to_bin` 产出），
//    **调用方必须用 `plist_mem_free` 释放**（不是 `free`，也不是 `idevice_data_free`）；
//    `*out_len` 为字节数。
//  - **失败**：返回 NULL，`*out_len` 为 0；`*out_err` 是 `malloc` 出来的 C 字符串，
//    **调用方用 `free` 释放**（可为 NULL，表示没有更细的原因）。
//  - **只读**：不挂载、不上传、不发信号、不改设备状态。
//  - **连接生命周期**：内部建**一条**服务连接，并在返回前 `image_mounter_free` 释放。
//    调用方必须保证「同一时刻只有这一条服务连接」（RSD 隧道并发铁律）。
//

#ifndef EscDDIProbe_h
#define EscDDIProbe_h

#include <stdint.h>

struct AdapterHandle;
struct RsdHandshakeHandle;

/// 只读诊断：经已建好的 RSD 隧道连 image_mounter，取「设备上已挂载的开发者镜像」清单。
///
/// - Parameters:
///   - adapter: RSD adapter 句柄（Swift 侧直接传 `OpaquePointer`）
///   - handshake: RSD 握手句柄（Swift 侧直接传 `OpaquePointer`）
///   - out_len: 出参，成功时为字节数
///   - out_err: 出参，失败时为 malloc 字符串（调用方 `free`）
/// - Returns: 成功 = binary plist 数组字节（每个元素是一个镜像字典；**空数组 = 设备未挂 DDI**），
///            调用方用 `plist_mem_free` 释放；失败 = NULL，原因见 `*out_err`。
unsigned char *esc_ddi_copy_devices(struct AdapterHandle *adapter,
                                    struct RsdHandshakeHandle *handshake,
                                    unsigned int *out_len,
                                    char **out_err);

#endif /* EscDDIProbe_h */
