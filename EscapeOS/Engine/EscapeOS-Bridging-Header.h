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

// 监督模式工具：通过私有 API 取已安装 App 图标（移植自 Lithium）
@interface UIImage (EscapeOSSupervised)
+ (instancetype)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                                 format:(int)format
                                                  scale:(CGFloat)scale;
@end

// 监督模式工具：设备本地枚举已安装应用（LSApplicationWorkspace 私有 API，
// 无需配对文件 / 本地隧道；与 Lithium 原版一致）
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

#endif /* EscapeOS_Bridging_Header_h */
