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

// Spike（待删）：CommerceKit CKSigningSession SAP 签名探测。
// 由 EscapeOS/Engine/CommerceKitSpike.m 实现，仅用于 P0 真机可行性验证。
int commercekit_sap_sign(
    const unsigned char *input,
    size_t inputLength,
    unsigned char **output,
    size_t *outputLength,
    char **errorMessage
);

#endif /* EscapeOS_Bridging_Header_h */
