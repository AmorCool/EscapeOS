//
//  EscRoutePeers.h
//  TequilaDash
//
//  从 IPv4 路由表枚举「出口接口为 utun*」的目的地址 / 网关.
//
//  为什么必须走 C 垫片：
//    `rt_msghdr` / `sockaddr_dl` / `RTAX_*` 定义在 `<net/route.h>`，
//    **该头不在 iOS 的 Swift Clang Importer 可见范围**（实测 CI：
//    `error: cannot find type 'rt_msghdr' in scope`）。
//    与本仓 `EscBrowseApps.c` / `EscDDIProbe.c` 同款处理：解析全在 C 层，
//    Swift 侧只拿字符串。
//
//  语义对齐 minimuxer 的 `destinationIPs` / `destinationGatewayIPs` /
//  `linkLayerDestinationIP`：这三者都来自路由表，不是 `ifa_dstaddr`。
//

#ifndef EscRoutePeers_h
#define EscRoutePeers_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 枚举出口接口为 `utun*` 的路由目的地址与网关.
///
/// - Parameter outCount: 非空时写入找到的条数.
/// - Returns: `malloc` 分配的逗号分隔 IPv4 字符串（如 `"10.7.0.1,10.7.1.1"`）；
///   无结果时返回 `NULL`。**调用方必须 `free()`**。
char *esc_route_utun_peers(size_t *outCount);

/// 释放 `esc_route_utun_peers` 的返回值（`NULL` 安全）.
void esc_route_utun_peers_free(char *value);

#ifdef __cplusplus
}
#endif

#endif /* EscRoutePeers_h */
