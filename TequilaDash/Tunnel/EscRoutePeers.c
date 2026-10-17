//
//  EscRoutePeers.c
//  TequilaDash
//
//  路由表 → utun 目的地址 / 网关。设计说明见 EscRoutePeers.h。
//
//  ## 为什么不用 getifaddrs 的 ifa_dstaddr
//  真机证据（2026-10-17 诊断页）：utun 接口存在，但 `ifa_dstaddr` 枚举出 0 个对端，
//  候选只剩兜底 10.7.0.1 ⇒ 连的是兜底值。而 minimuxer 的
//  `destinationIPs` / `destinationGatewayIPs` / `linkLayerDestinationIP`
//  三个都来自**路由表**。所以这里按路由表取。
//
//  ## 为什么自声明结构体而不是 #include <net/route.h>
//  **iOS 公共 SDK 不含 `net/route.h`**（CI 实测：`'net/route.h' file not found`）。
//  该头在 Darwin 里属系统内部头。所以这里只复制**实际用到的**布局：
//  消息头前 36 字节（到 `rtm_inits`）+ `rt_metrics` 60 字节 = **96 字节**，
//  随后才是 sockaddr 数组。字段名一律加 `esc_` 前缀，避免与任何系统头冲突。
//
//  ## 解析要点（BSD 路由消息布局）
//  1. `sysctl(CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP)` 返回一串变长记录；
//  2. 每条记录是 96 字节消息头 + 最多 `RTAX_MAX` 个 sockaddr；
//  3. 哪些 sockaddr 存在由 `rtm_addrs` 的位掩码决定，顺序固定为
//     DST(0) GATEWAY(1) NETMASK(2) GENMASK(3) IFP(4) IFA(5) …
//  4. 每个 sockaddr 按 **4 字节 ROUNDUP** 推进（`sa_len` 不含填充）；
//  5. `RTAX_IFP` 是 `sockaddr_dl`，`sdl_data` 前 `sdl_nlen` 字节是接口名；
//     点对点链路的 `RTAX_GATEWAY` 也是 `sockaddr_dl`，其地址区尾部 4 字节是对端 IPv4。
//

#include "EscRoutePeers.h"

#include <net/if.h>
#include <net/if_dl.h>      // sockaddr_dl / sdl_nlen / sdl_alen（公共 SDK 里**有**）
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// net/route.h 不在 iOS 公共 SDK 里，这里按 Darwin 布局自声明（见文件头说明）.
#ifndef NET_RT_DUMP
#define NET_RT_DUMP 4
#endif
#define ESC_RTAX_DST      0
#define ESC_RTAX_GATEWAY  1
#define ESC_RTAX_NETMASK  2
#define ESC_RTAX_GENMASK  3
#define ESC_RTAX_IFP      4
#define ESC_RTAX_IFA      5
#define ESC_RTAX_MAX      8

/// `struct rt_metrics` 的等价布局（15 × uint32 = 60 字节）.
typedef struct {
    uint32_t esc_metrics[15];
} esc_rt_metrics;

/// `struct rt_msghdr` 的等价布局（36 + 60 = 96 字节）.
/// 只读前两个字段（`msglen` / `addrs`），其余字段仅为**对齐占位**.
typedef struct {
    uint16_t esc_msglen;
    uint8_t  esc_version;
    uint8_t  esc_type;
    uint16_t esc_index;
    int32_t  esc_flags;
    int32_t  esc_addrs;
    int32_t  esc_pid;
    int32_t  esc_seq;
    int32_t  esc_errno;
    int32_t  esc_use;
    uint32_t esc_inits;
    esc_rt_metrics esc_rmx;
} esc_rt_msghdr;

/// 编译期校验：与 Darwin `sizeof(struct rt_msghdr)` 一致（96）.
/// 若某天布局变化，这里会先炸而不是静默解析错位.
typedef char esc_rt_msghdr_size_check[(sizeof(esc_rt_msghdr) == 96) ? 1 : -1];

#define ESC_MAX_PEERS 16
#define ESC_MAX_IFNAME 32

/// 4 字节对齐（BSD 路由消息里 sockaddr 之间的推进口径）.
static size_t esc_roundup(size_t length) {
    return length > 0 ? ((length + sizeof(uint32_t) - 1) & ~(sizeof(uint32_t) - 1)) : sizeof(uint32_t);
}

/// 从 `sockaddr_dl` 取接口名（`sdl_data` 前 `sdl_nlen` 字节）.
static void esc_ifname_from_dl(const struct sockaddr_dl *dl, char *out, size_t capacity) {
    out[0] = '\0';
    if (dl == NULL || capacity == 0) return;
    size_t nameLength = (size_t)dl->sdl_nlen;
    if (nameLength == 0 || nameLength >= capacity) return;
    memcpy(out, dl->sdl_data, nameLength);
    out[nameLength] = '\0';
}

/// 从 `sockaddr_dl` 的地址区取对端 IPv4（点对点链路）.
static int esc_peer_from_dl(const struct sockaddr_dl *dl, struct in_addr *out) {
    if (dl == NULL || out == NULL) return 0;
    if (dl->sdl_alen < 4) return 0;
    const unsigned char *address = (const unsigned char *)dl->sdl_data + dl->sdl_nlen;
    if (dl->sdl_alen >= 8) {
        // 部分实现会在地址区前置 4 字节；取尾部 4 字节更稳.
        address += dl->sdl_alen - 4;
    }
    unsigned char bytes[4] = { address[0], address[1], address[2], address[3] };
    if (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0) return 0;
    memcpy(out, bytes, 4);
    return 1;
}

/// 收集一个候选（去重、跳过非法值）.
static void esc_push(struct in_addr value, struct in_addr *list, size_t *count) {
    if (value.s_addr == 0 || value.s_addr == INADDR_ANY || value.s_addr == INADDR_BROADCAST) return;
    unsigned char first = ((unsigned char *)&value.s_addr)[0];
    if (first == 127 || first == 224 || first == 239) return;   // 回环 / 组播
    for (size_t i = 0; i < *count; i++) {
        if (list[i].s_addr == value.s_addr) return;
    }
    if (*count < ESC_MAX_PEERS) {
        list[(*count)++] = value;
    }
}

char *esc_route_utun_peers(size_t *outCount) {
    if (outCount != NULL) *outCount = 0;

    int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0 };
    size_t needed = 0;
    if (sysctl(mib, 6, NULL, &needed, NULL, 0) != 0 || needed == 0) return NULL;

    char *buffer = malloc(needed);
    if (buffer == NULL) return NULL;
    if (sysctl(mib, 6, buffer, &needed, NULL, 0) != 0) {
        free(buffer);
        return NULL;
    }

    struct in_addr peers[ESC_MAX_PEERS];
    size_t peerCount = 0;

    size_t offset = 0;
    while (offset + sizeof(esc_rt_msghdr) <= needed) {
        const esc_rt_msghdr *header = (const esc_rt_msghdr *)(const void *)(buffer + offset);
        size_t messageLength = (size_t)header->esc_msglen;
        if (messageLength <= sizeof(esc_rt_msghdr) || offset + messageLength > needed) break;

        // 逐条 sockaddr：RTAX 顺序，按 rtm_addrs 位掩码判断存在性.
        const char *cursor = buffer + offset + sizeof(esc_rt_msghdr);
        const char *end = buffer + offset + messageLength;
        char interfaceName[ESC_MAX_IFNAME] = { 0 };
        struct in_addr destination = { 0 };
        struct in_addr gateway = { 0 };
        int hasDestination = 0;
        int hasGateway = 0;

        for (int index = 0; index < ESC_RTAX_MAX && cursor + sizeof(struct sockaddr) <= end; index++) {
            const struct sockaddr *sa = (const struct sockaddr *)(const void *)cursor;
            size_t length = (size_t)sa->sa_len;
            if (length == 0) break;

            if ((header->esc_addrs & (1 << index)) != 0) {
                switch (index) {
                    case ESC_RTAX_DST:
                        if (sa->sa_family == AF_INET) {
                            const struct sockaddr_in *sin = (const struct sockaddr_in *)(const void *)sa;
                            destination = sin->sin_addr;
                            hasDestination = 1;
                        }
                        break;
                    case ESC_RTAX_GATEWAY:
                        if (sa->sa_family == AF_INET) {
                            const struct sockaddr_in *sin = (const struct sockaddr_in *)(const void *)sa;
                            gateway = sin->sin_addr;
                            hasGateway = 1;
                        } else if (sa->sa_family == AF_LINK) {
                            struct in_addr peer = { 0 };
                            if (esc_peer_from_dl((const struct sockaddr_dl *)(const void *)sa, &peer)) {
                                gateway = peer;
                                hasGateway = 1;
                            }
                        }
                        break;
                    case ESC_RTAX_IFP:
                        if (sa->sa_family == AF_LINK) {
                            esc_ifname_from_dl((const struct sockaddr_dl *)(const void *)sa,
                                               interfaceName, sizeof(interfaceName));
                        }
                        break;
                    default:
                        break;
                }
            }

            size_t advance = esc_roundup(length);
            if (advance == 0 || cursor + advance > end) break;
            cursor += advance;
        }

        if (strncmp(interfaceName, "utun", 4) == 0) {
            if (hasDestination) esc_push(destination, peers, &peerCount);
            if (hasGateway) esc_push(gateway, peers, &peerCount);
        }

        offset += messageLength;
    }

    free(buffer);

    if (peerCount == 0) return NULL;

    // 拼成逗号分隔的 IPv4 字符串.
    size_t capacity = peerCount * (INET_ADDRSTRLEN + 1) + 1;
    char *result = malloc(capacity);
    if (result == NULL) return NULL;
    result[0] = '\0';
    size_t used = 0;
    for (size_t i = 0; i < peerCount; i++) {
        char text[INET_ADDRSTRLEN] = { 0 };
        if (inet_ntop(AF_INET, &peers[i], text, sizeof(text)) == NULL) continue;
        int written = snprintf(result + used, capacity - used, "%s%s", (used == 0 ? "" : ","), text);
        if (written <= 0 || (size_t)written >= capacity - used) break;
        used += (size_t)written;
    }

    if (used == 0) {
        free(result);
        return NULL;
    }
    if (outCount != NULL) *outCount = peerCount;
    return result;
}

void esc_route_utun_peers_free(char *value) {
    free(value);
}
