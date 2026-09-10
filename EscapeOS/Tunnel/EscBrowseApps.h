//
//  EscBrowseApps.h
//  EscapeOS
//
//  v0.3.279：instproxy Browse 的 C 垫片。
//
//  背景：Swift 侧直接调 `installation_proxy_browse` 时，`plist_t`（= typedef void *）
//  的指针参数在 Clang Importer 下类型推断极不稳定（v0.3.271~278 八轮 CI 全部因
//  类型不匹配失败，报错文字自相矛盾）。本垫片把 plist 构造/遍历/序列化全部留在
//  C 层（类型天然精确），Swift 侧只传「C 字符串数组 + 整数长度」，拿回「bplist 字节」。
//

#ifndef EscBrowseApps_h
#define EscBrowseApps_h

#include <stdint.h>

struct InstallationProxyClientHandle;

/// 以给定 ReturnAttributes 执行一次 instproxy Browse。
/// - Parameters:
///   - ip: installation_proxy 客户端句柄（Swift 侧 OpaquePointer）
///   - attrs: C 字符串数组（如 "StaticDiskUsage"/"DynamicDiskUsage"/"iTunesMetadata"...）
///   - attrs_count: 数组元素个数
///   - out_len: 出参，返回字节长度
/// - Returns: 单个 plist array（每个元素是一个 app 字典）的 binary plist 字节；
///            失败返回 NULL。**调用方用 plist_mem_free 释放**。
uint8_t *esc_browse_apps_bin(struct InstallationProxyClientHandle *ip,
                             char **attrs,
                             int attrs_count,
                             uint32_t *out_len);

#endif /* EscBrowseApps_h */
