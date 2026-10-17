//
//  TunnelContext.h
//  TequilaDash
//
//  Two LocalDevVPN paths, same pairing file iLoader writes (lockdown + RP keys):
//  iOS 26.4+ uses RPPairing/RSD on 10.7.0.1:49152; iOS 18 uses lockdown TCP on
//  port 62078. Try RP first, then classic.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "idevice.h"

NS_ASSUME_NONNULL_BEGIN

@interface TunnelContext : NSObject {
    @protected struct AdapterHandle *_adapter;
    @protected struct RsdHandshakeHandle *_handshake;
    @protected struct IdeviceProviderHandle *_provider;
    @protected BOOL _tunnelConnecting;
    @protected NSError *_Nullable _lastTunnelError;
}

@property (class, readonly) TunnelContext *shared;

/// Whether a pairing file is present on disk.
@property (nonatomic, readonly) BOOL hasPairingFile;

/// **只读**：当前是否已有可用隧道句柄（RSD 或 lockdown 任一）.
/// 诊断页用 —— **不建连、不改状态**（v0.3.620：诊断绝不能触发握手）.
@property (nonatomic, readonly) BOOL hasActiveTunnel;

/// **只读**：是否正在建连（诊断页用，避免显示成「未连接」误导）.
@property (nonatomic, readonly) BOOL isConnecting;

/// Save a user-imported pairing file (contents of a .mobiledevicepairing plist).
- (BOOL)savePairingFile:(NSString *)contents error:(NSError **)error;

/// Remove the stored pairing file.
- (void)resetPairingFile;

/// Connect over LocalDevVPN. Tries Remote Pairing (iOS 26.4+), then lockdown (iOS 18).
/// Returns YES on success; on failure fills error.
- (BOOL)startHeartbeat:(NSError **)error;

/// Start the tunnel only if no RSD or lockdown provider is already up.
- (BOOL)ensureHeartbeatWithError:(NSError **)error;

/// Enumerate all installed apps (full info dictionaries). Requires tunnel.
- (nullable NSDictionary<NSString *, NSDictionary *> *)getAllAppsInfoWithError:(NSError **)error;

/// Fetch an app's SpringBoard icon PNG.
- (nullable UIImage *)getAppIconWithBundleId:(NSString *)bundleId error:(NSError **)error;

/// Uninstall a user app through the active tunnel (RPPairing on iOS 26.4+,
/// lockdown on iOS 18). The pairing file authenticates the operation with
/// `installd`, so no in-process `com.apple.private.mobileinstallation.allow-uninstall`
/// entitlement is required (TequilaDash only carries `get-task-allow`).
/// Returns YES on success; on failure fills `error`.
- (BOOL)uninstallAppWithBundleId:(NSString *)bundleId error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
