// Jackson Coxson
// heartbeat.c

#include "idevice.h"
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/_types/_u_int64_t.h>
#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>
#include "heartbeat.h"
#include <pthread.h>
// v0.3.614：与 TunnelContext._targetIP / Swift LocalDevVPN.targetIP 同口径地推导 utun 对端.
#include <ifaddrs.h>
#include <netinet/in.h>
// v0.3.636：globalHeartbeatToken 改成 _Atomic，读写要用 atomic_load（见 heartbeat.h）。
#include <stdatomic.h>
@import Foundation;

// v0.3.636：_Atomic（跨线程读写，见 heartbeat.h 的说明）。
_Atomic int globalHeartbeatToken = 0;
NSDate* lastHeartbeatDate = nil;

/// 隧道目标 IP：**与 `TunnelContext._targetIP` 同口径的两级优先级**
/// （用户覆盖 → 兜底 10.7.0.1）。
///
/// v0.3.615 **回滚**：撤回 v0.3.614 加的 utun 对端自动推导。
/// 原因见 `TunnelContext.m` 的 `_targetIP` 注释 —— 推导会取到「第一个 utun」，
/// 设备上多 VPN 并存时取错隧道。SideStore 那边（`Minimuxer`）是把 `10.7.0.1` 写死的，
/// 没有这种推导；本仓不该自己发明。
static NSString* tequiladash_tunnel_target_ip(void) {
    NSString* stored = [[NSUserDefaults standardUserDefaults] stringForKey:@"TunnelDeviceIP"];
    if (stored.length > 0) {
        return stored;
    }
    return @"10.7.0.1";
}

void startHeartbeat(IdevicePairingFile* pairing_file, IdeviceProviderHandle** provider, int heartbeatToken, HeartbeatCompletionHandlerC completion) {
    IdeviceProviderHandle* newProvider = *provider;
    IdeviceFfiError* err = nil;

    // Create the socket address (replace with your device's IP)
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(LOCKDOWN_PORT);

    // 目标 IP 解析：用户覆盖 → 10.7.0.1（两级，与 TunnelContext._targetIP 同口径）。
    //
    // v0.3.640 更正注释：这里原写「三级解析」，但 v0.3.615 已把 utun 自动推导回滚了，
    // 现在实际只有两级 —— 注释停留在旧口径会误导后续维护。
    NSString* deviceIP = tequiladash_tunnel_target_ip();
    // v0.3.640：必须校验 inet_pton 返回值。
    // 失败时 addr.sin_addr 保持全 0 ⇒ 会去连 0.0.0.0:62078（必然失败），
    // 而错误只报「连不上」，看不出是 IP 非法。
    if (inet_pton(AF_INET, [deviceIP UTF8String], &addr.sin_addr) != 1) {
        completion(-1, "invalid TunnelDeviceIP");
        idevice_pairing_file_free(pairing_file);
        return;
    }
    
    
    err = idevice_tcp_provider_new((struct sockaddr *)&addr, pairing_file,
                                   "ExampleProvider", &newProvider);
    if (err != NULL) {
        fprintf(stderr, "Failed to create TCP provider: [%d] %s", err->code,
                err->message);
        completion(err->code, err->message);
        idevice_pairing_file_free(pairing_file);
        idevice_error_free(err);
        
        return;
    }
    
    // Connect to installation proxy
    HeartbeatClientHandle *client = NULL;
    err = heartbeat_connect(newProvider, &client);
    if (err != NULL) {
        fprintf(stderr, "Failed to connect to installation proxy: [%d] %s",
                err->code, err->message);
        completion(err->code, err->message);
        idevice_provider_free(newProvider);
        idevice_error_free(err);
        
        return;
    }
        

        *provider = newProvider;
    

    // 首个成功/失败回调只发一次：置位后所有后续分支不再回调，
    // 避免调用方在首拍之后又收到一条与本地状态不一致的失败.
    bool completionCalled = false;
    
    u_int64_t current_interval = 15;
    while (1) {
        // Get the new interval
        u_int64_t new_interval = 0;
        err = heartbeat_get_marco(client, current_interval, &new_interval);
        if (err != NULL) {
            fprintf(stderr, "Failed to get marco: [%d] %s token = %d, pthread_self = %p\n", err->code, err->message, heartbeatToken, pthread_self());
            // 首拍之后心跳断了也必须通知：原先这里被 completionCalled 挡住，
            // 结果 TunnelContext 仍把 _provider 当可用隧道（hasActiveTunnel 返回 YES），
            // ensureHeartbeat 因「已有句柄」直接返回成功、不再重建 ——
            // 用户看到的是「一直连着，但所有操作都失败」。
            if (heartbeatToken == atomic_load(&globalHeartbeatToken)) {
                completionCalled = true;
                completion(err->code, err->message);
            }
            heartbeat_client_free(client);
            idevice_error_free(err);
            return;
        }
        
        // if a new heartbeat thread is running we quit current one
        if (heartbeatToken != atomic_load(&globalHeartbeatToken)) {
            heartbeat_client_free(client);

            NSLog(@"Quitting %d, now token = %d", heartbeatToken, atomic_load(&globalHeartbeatToken));
            return;
        }
        
        current_interval = new_interval + 5;
        
        // Reply
        err = heartbeat_send_polo(client);
        if (err != NULL) {
            fprintf(stderr, "Failed to get marco: [%d] %s", err->code, err->message);
            // 同上：心跳中途断掉要通知，否则隧道死了没人知道.
            if (heartbeatToken == atomic_load(&globalHeartbeatToken)) {
                completionCalled = true;
                completion(err->code, err->message);
            }
            heartbeat_client_free(client);
            idevice_error_free(err);

            return;
        }
        
        // ⚠️ 这个分支**不能回调 completion**（v0.3.635 修复 v0.3.621 引入的回归）。
        //
        // 为什么：
        //   · completion 回调在 TunnelContext 里会走 `_providerDiedWithToken`，
        //     而那里会 `_freeTunnelHandles` —— **把 provider 释放掉**。
        //   · 而本分支的触发条件是 `now - lastHeartbeatDate > current_interval`，
        //     `current_interval = new_interval + 5`，`new_interval` 由设备给。
        //     只要设备给的间隔略小于实际握手耗时，这个判断**每轮都会成立**。
        //   · 结果：隧道建好 → 心跳走一轮 → 判超时 → 回调 → 拆隧道 → 重建 → 再拆……
        //     用户看到的就是「完全没法连接隧道」。
        //
        // 这个分支原本（v0.3.620 及之前）只 `return` 退出线程、**不通知任何人**，
        // 所以是安全的 —— 隧道句柄仍在，下次业务请求会照常用。
        // 我 v0.3.621 为了「心跳死了要让人知道」给它加了回调，反而把
        // 「一次心跳异常」放大成了「隧道被拆」。
        //
        // 正确的做法（如果将来要补「心跳死亡通知」）：
        //   只在 **marco/polo 真失败**（:91 / :118）时通知，因为那才是连接真断了；
        //   而本分支是**本地计时判定**，不代表连接已断，不该触发拆隧道。
        if (lastHeartbeatDate && [[NSDate now] timeIntervalSinceDate:lastHeartbeatDate] > current_interval) {
            lastHeartbeatDate = nil;
            // 超时退出同样要释放心跳客户端（原先直接 return 泄漏了 client）.
            heartbeat_client_free(client);
            return;
        }
        lastHeartbeatDate = [NSDate now];


        if (!completionCalled) {
            completionCalled = true;
            completion(0, "Heartbeat succeeded");
        }
    }
}
