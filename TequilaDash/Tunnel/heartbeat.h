//
//  heartbeat.h
//  StikJIT
//
//  Created by Stephen on 3/27/25.
//

// heartbeat.h
#ifndef HEARTBEAT_H
#define HEARTBEAT_H
#include "idevice.h"
@import Foundation;

typedef void (^HeartbeatCompletionHandlerC)(int result, const char *message);
typedef void (^LogFuncC)(const char* message, ...);

/// 全局心跳代际。
///
/// v0.3.636：改成 `_Atomic int`（原先裸 `int`）。
///
/// 它**跨线程**读写：建连 worker（TunnelContext.m）、心跳线程（本文件）、
/// resetPairingFile、_freeTunnelHandles。C 里非原子 int 的跨线程读写是数据竞争（UB），
/// 且编译器可以把 `while (1)` 里的值提到寄存器，导致心跳线程永远看不到新值 ——
/// 那样「换隧道时旧 worker 退出」这套机制本身就失效了。
extern _Atomic int globalHeartbeatToken;
extern NSDate* lastHeartbeatDate;

void startHeartbeat(IdevicePairingFile* pairing_file, IdeviceProviderHandle** provider, int heartbeatToken, HeartbeatCompletionHandlerC completion);
#endif /* HEARTBEAT_H */
