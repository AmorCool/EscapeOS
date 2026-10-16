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
@import Foundation;

int globalHeartbeatToken = 0;
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

    // v0.3.614：改走同口径的三级解析（此前只读 TunnelDeviceIP、空了直接 10.7.0.1，
    // 与 Swift 侧会自动推导 utun 对端不一致 ⇒ 预检通过但建隧道失败）。
    NSString* deviceIP = tequiladash_tunnel_target_ip();
    inet_pton(AF_INET, [deviceIP UTF8String], &addr.sin_addr);
    
    
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
            if(!completionCalled) {
                completionCalled = true;
                completion(err->code, err->message);
            }
            heartbeat_client_free(client);
            idevice_error_free(err);
            return;
        }
        
        // if a new heartbeat thread is running we quit current one
        if (heartbeatToken != globalHeartbeatToken) {
            heartbeat_client_free(client);

            NSLog(@"Quitting %d, now token = %d", heartbeatToken, globalHeartbeatToken);
            return;
        }
        
        current_interval = new_interval + 5;
        
        // Reply
        err = heartbeat_send_polo(client);
        if (err != NULL) {
            fprintf(stderr, "Failed to get marco: [%d] %s", err->code, err->message);
            if(!completionCalled) {
                completionCalled = true;
                completion(err->code, err->message);
            }
            heartbeat_client_free(client);
            idevice_error_free(err);

            return;
        }
        
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
