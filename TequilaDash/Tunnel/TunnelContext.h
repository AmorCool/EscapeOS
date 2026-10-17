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

/// **只读**：配对文件能否被 **RPPairing** 解析（v0.3.639 新增）.
///
/// 为什么需要它：`hasPairingFile` 只查 `fileExistsAtPath` ——
/// 一个截断 / 损坏 / 格式不对（例如把 lockdown 版 `.mobiledevicepairing`
/// 改名成 `pairingFile.plist`）的文件也会返回 YES。
/// 诊断页于是打绿勾「已导入」，而真正建隧道时 `rp_pairing_file_read` 失败
/// ⇒ 必然连不上，且用户被告知「配对文件已导入」—— 这是最误导人的一个盲区。
///
/// 本属性做一次**纯内存解析**：读文件 + `rp_pairing_file_read` + 立刻释放。
/// **不建套接字、不碰隧道状态**，符合「诊断只读」纪律。
@property (nonatomic, readonly) BOOL isPairingFileParsable;

/// **只读**：配对文件解析失败的原因（`isPairingFileParsable == NO` 时非空）.
@property (nonatomic, readonly, nullable) NSString *pairingFileParseError;

/// **只读**：当前是否已有可用隧道句柄（RSD 或 lockdown 任一）.
/// 诊断页用 —— **不建连、不改状态**（v0.3.620：诊断绝不能触发握手）.
@property (nonatomic, readonly) BOOL hasActiveTunnel;

/// **只读**：是否正在建连（诊断页用，避免显示成「未连接」误导）.
@property (nonatomic, readonly) BOOL isConnecting;

/// **只读**：最近一次建连失败的原因（v0.3.639 新增）.
///
/// 为什么必须暴露它：`_lastTunnelError` 是全仓**唯一**记录真实失败原因的地方
/// （含 RPPairing 与 lockdown 两条路径各自的错误文本、以及心跳中断原因）。
/// 但它此前只是 `@protected` ivar、没有对外 getter —— 诊断页只能显示
/// 「utun=存在 / 目标对端=不可达 / 句柄=未建立」这类**现象**，
/// 永远看不到「为什么」，这正是「完全连不上但说不清原因」的直接成因。
///
/// 语义：**不建连、不改状态**，只读已有 ivar（与 `isConnecting` 同款）。
@property (nonatomic, readonly, nullable) NSError *lastTunnelError;

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
