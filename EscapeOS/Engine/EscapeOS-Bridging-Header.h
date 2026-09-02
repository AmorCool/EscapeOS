//
//  EscapeOS-Bridging-Header.h
//  EscapeOS
//
//  Exposes the bad_query primitive and the RPPairing tunnel context to Swift.
//

#ifndef EscapeOS_Bridging_Header_h
#define EscapeOS_Bridging_Header_h

#include "bad_query.h"
#include "zip_crypto.h"

// v0.3.8：JIT 探测——csops 读取自身代码签名标志。CS_DEBUGGED(0x10000000) 是
// 「调试器（StikDebug/debugserver）已附加并生效」的内核级判据，比 mmap MAP_JIT
// 探测准确（iOS 27 beta 实锤：mmap 成功但执行仍被 CODESIGNING Invalid Page 杀）。
#include <sys/types.h>
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#import "../Tunnel/TunnelContext.h"

// MHA branch: MCM integration layer (bad_query + MobileHouseArrest)
#import "MCM/MCMBridge.h"
#import "MCM/BQMCMIntegration.h"

// iOS 27 device-initiated wireless pairing host wrapper
#import "../Tunnel/WirelessPairing.h"

// IPA 侧载：Apple ID 登录 + 签名（isideload sign-only 路径）
#include "../Tunnel/sideload_auth.h"

// SAP 签名桥（纯软件 Unicorn 模拟 Apple CommerceKit，PR #525 移植）。
// libsap.a / sap.h 由 sapbridge/build-sap.sh 在编译前生成，位于 sapbridge/build/。
#include "sap.h"

// Lua 模块宿主（v0.3.95：Rust+mlua 解释器，编进 App 跟随签名，模块=纯 Lua 脚本）
#include "rust-lua-host.h"

// 监督模式工具：通过私有 API 取已安装 App 图标（移植自 Lithium）
@interface UIImage (EscapeOSSupervised)
+ (instancetype)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                                 format:(int)format
                                                  scale:(CGFloat)scale;
@end

#endif /* EscapeOS_Bridging_Header_h */
