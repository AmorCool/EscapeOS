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

/// 隧道目标 IP：与 `TunnelContext._targetIP` **完全同口径**的三级优先级
/// （用户覆盖 → utun 对端自动推导 → 兜底 10.7.0.1）。
///
/// 为什么在这里也做一遍（而不是让调用方传进来）：`startHeartbeat` 的签名被多处调用，
/// 改签名牵动面大；而这里的解析逻辑很短、判据固定，重复一份比改接口更稳。
/// 若将来要统一，应把本函数与 `TunnelContext._utunPeerIPv4` 抽成一个共享 C 函数。
static NSString* tequiladash_tunnel_target_ip(void) {
    NSString* stored = [[NSUserDefaults standardUserDefaults] stringForKey:@"TunnelDeviceIP"];
    if (stored.length > 0) {
        return stored;
    }

    struct ifaddrs* addrs = NULL;
    if (getifaddrs(&addrs) == 0 && addrs != NULL) {
        NSString* found = nil;
        for (struct ifaddrs* ifa = addrs; ifa != NULL; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (ifa->ifa_name == NULL || strncmp(ifa->ifa_name, "utun", 4) != 0) continue;
            if (ifa->ifa_dstaddr == NULL) continue;

            struct sockaddr_in* dst = (struct sockaddr_in*)ifa->ifa_dstaddr;
            char buf[INET_ADDRSTRLEN] = {0};
            if (inet_ntop(AF_INET, &dst->sin_addr, buf, sizeof(buf)) == NULL) continue;

            NSString* ip = [NSString stringWithUTF8String:buf];
            if (ip.length == 0) continue;
            if ([ip isEqualToString:@"0.0.0.0"] || [ip isEqualToString:@"255.255.255.255"]) continue;
            if ([ip hasPrefix:@"127."] || [ip hasPrefix:@"224."] || [ip hasPrefix:@"239."]) continue;

            found = ip;
            break;
        }
        freeifaddrs(addrs);
        if (found.length > 0) {
            return found;
        }
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
    

    bool completionCalled = false;
    
    u_int64_t current_interval = 15;
    while (1) {
        // Get the new interval
        u_int64_t new_interval = 0;
        err = heartbeat_get_marco(client, current_interval, &new_interval);
        if (err != NULL) {
            fprintf(stderr, "Failed to get marco: [%d] %s token = %d, pthread_self = %p\n", err->code, err->message, heartbeatToken, pthread_self());
            if(!completionCalled) {
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
                completion(err->code, err->message);
            }
            heartbeat_client_free(client);
            idevice_error_free(err);

            return;
        }
        
        if (lastHeartbeatDate && [[NSDate now] timeIntervalSinceDate:lastHeartbeatDate] > current_interval) {
            lastHeartbeatDate = nil;
            return;
        }
        lastHeartbeatDate = [NSDate now];


        if (!completionCalled) {
            completion(0, "Heartbeat succeeded");
        }
    }
}
