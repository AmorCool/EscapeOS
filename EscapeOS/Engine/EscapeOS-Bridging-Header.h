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
#import "../Tunnel/TunnelContext.h"

// MHA branch: MCM integration layer (bad_query + MobileHouseArrest)
#import "MCM/MCMBridge.h"
#import "MCM/BQMCMIntegration.h"

// iOS 27 device-initiated wireless pairing host wrapper
#import "../Tunnel/WirelessPairing.h"

// IPA 侧载：Apple ID 登录 + 签名（isideload sign-only 路径）
#include "../Tunnel/sideload_auth.h"

// 监督模式工具：通过私有 API 取已安装 App 图标（移植自 Lithium）
@interface UIImage (EscapeOSSupervised)
+ (instancetype)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                                 format:(int)format
                                                  scale:(CGFloat)scale;
@end

#endif /* EscapeOS_Bridging_Header_h */
