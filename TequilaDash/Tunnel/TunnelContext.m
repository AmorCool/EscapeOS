//
//  TunnelContext.m
//  TequilaDash
//
//  RPPairing tunnel over LocalDevVPN loopback (default 10.7.0.1:49152).
//  Adapted from StikDebug's JITEnableContext / IdeviceFFIBridge (iOS 26.4+ path).
//

#import "TunnelContext.h"
#import "applist.h"
#import "heartbeat.h"
#include <arpa/inet.h>
#include <os/lock.h>
// v0.3.614：_targetIP 需要与本 App Swift 侧 LocalDevVPN.targetIP 同口径地
// 自动推导 utun 对端地址，故引入 getifaddrs / sockaddr_in.
#include <ifaddrs.h>
#include <netinet/in.h>
#include <string.h>

#define RPPPAIRING_PORT 49152
#define DEFAULT_TUNNEL_IP @"10.7.0.1"

@implementation TunnelContext {
    os_unfair_lock _tunnelLock;
    dispatch_semaphore_t _tunnelSemaphore;
    NSRecursiveLock *_handleLock;
}

+ (instancetype)shared {
    static TunnelContext *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[TunnelContext alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _adapter = NULL;
        _handshake = NULL;
        _provider = NULL;
        _tunnelConnecting = NO;
        _tunnelLock = OS_UNFAIR_LOCK_INIT;
        _tunnelSemaphore = NULL;
        _lastTunnelError = nil;
        _handleLock = [NSRecursiveLock new];
        _handleLock.name = @"TequilaDash.Tunnel.handles";

        NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSString *logPath = [docs URLByAppendingPathComponent:@"idevice_log.txt"].path;
        idevice_init_logger(Debug, Debug, (char *)logPath.fileSystemRepresentation);
    }
    return self;
}

- (NSError *)_error:(NSString *)msg code:(int)code {
    return [NSError errorWithDomain:@"TequilaDash.Tunnel" code:code
        userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

- (NSURL *)_pairingFileURL {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [docs URLByAppendingPathComponent:@"pairingFile.plist"];
}

- (BOOL)hasPairingFile {
    return [NSFileManager.defaultManager fileExistsAtPath:self._pairingFileURL.path];
}

/// **只读**：已有可用句柄. 不建连、不改状态.
- (BOOL)hasActiveTunnel {
    [_handleLock lock];
    BOOL up = [self _hasUsableHandlesLocked];
    [_handleLock unlock];
    return up;
}

/// **只读**：是否正在建连.
- (BOOL)isConnecting {
    os_unfair_lock_lock(&_tunnelLock);
    BOOL connecting = _tunnelConnecting;
    os_unfair_lock_unlock(&_tunnelLock);
    return connecting;
}

- (BOOL)savePairingFile:(NSString *)contents error:(NSError **)error {
    BOOL looksLikePairing = [contents containsString:@"DeviceCertificate"]
        || ([contents containsString:@"identifier"] && [contents containsString:@"public_key"]);
    if (!looksLikePairing) {
        if (error) *error = [self _error:@"That file is not a valid pairing file." code:-2];
        return NO;
    }
    return [contents writeToURL:self._pairingFileURL atomically:YES encoding:NSUTF8StringEncoding error:error];
}

- (void)resetPairingFile {
    [NSFileManager.defaultManager removeItemAtURL:self._pairingFileURL error:nil];
    // 注意：**不要写 `[self _handleLock lock]`** —— clang 会把 `_handleLock` 当成
    // 选择器首段、再要求 `lock` 带 `:`，报 `error: expected ':'`。
    // 直接用 ivar（`[_handleLock lock]`）或显式 `self->_handleLock`。
    [_handleLock lock];
    globalHeartbeatToken++;          // 让进行中的 worker（如有）写回时能被识别为过期
    [self _freeTunnelHandles];
    [_handleLock unlock];
}

/// 心跳线程报告隧道已死：清掉句柄，让下一次 ensureHeartbeat 真的重建.
///
/// 只在 token 仍然匹配时动手 —— 否则说明已经换了新隧道，这条通知属于旧 worker，
/// 清理会误杀新句柄.
- (void)_providerDiedWithToken:(int)token reason:(NSString *)reason code:(int)code {
    [_handleLock lock];
    BOOL stale = (token != globalHeartbeatToken);
    if (!stale && _provider != NULL) {
        NSLog(@"[TequilaDash] heartbeat died (code=%d, %@) —— 清理隧道句柄以便下次重建",
              code, reason ?: @"");
        [self _freeTunnelHandles];   // 内部会 globalHeartbeatToken++ 并释放 provider
    }
    [_handleLock unlock];
    if (stale) {
        return;
    }
    os_unfair_lock_lock(&_tunnelLock);
    _lastTunnelError = [self _error:[NSString stringWithFormat:@"隧道心跳中断：%@", reason ?: @"unknown"]
                               code:code];
    os_unfair_lock_unlock(&_tunnelLock);
}

/// 释放全部隧道句柄. **调用方必须已持有 `_handleLock`**（递归锁，允许嵌套）.
- (void)_freeTunnelHandles {
    if (_provider) {
        globalHeartbeatToken++;
        idevice_provider_free(_provider);
        _provider = NULL;
    }
    if (_handshake) {
        rsd_handshake_free(_handshake);
        _handshake = NULL;
    }
    if (_adapter) {
        adapter_free(_adapter);
        _adapter = NULL;
    }
}

/// 取当前可用句柄（持有 `_handleLock` 期间调用），返回 YES 表示至少有一条可用.
/// 避免调用方直接读实例变量时与建连/释放竞态.
- (BOOL)_hasUsableHandlesLocked {
    return (_adapter && _handshake) || _provider != NULL;
}

/// 建连中就别抢句柄锁 —— 否则调用方（可能在主线程）会被 30 秒的握手卡住.
/// 返回 YES 表示「正在建连，本次直接失败，请稍后重试」.
- (BOOL)_rejectIfConnectingWithError:(NSError **)error {
    os_unfair_lock_lock(&_tunnelLock);
    BOOL connecting = _tunnelConnecting;
    os_unfair_lock_unlock(&_tunnelLock);
    if (connecting) {
        if (error) *error = [self _error:@"Tunnel is connecting; retry shortly." code:-8];
        return YES;
    }
    return NO;
}

/// 隧道目标 IP（= LocalDevVPN 的**对端地址**）.
///
/// v0.3.615 **回滚**：撤回 v0.3.614 加的「utun 对端自动推导」。
///
/// 为什么回滚（用户实测报障：「wifi隧道连接也用不了」）：
///   推导取的是「**第一个** utun 接口的 `ifa_dstaddr`」。设备上若同时装着
///   Surge / Loon / Shadowrocket / WireGuard 等（各起一条 utun），**取到的很可能不是
///   LocalDevVPN 那条** ⇒ 隧道指向错误地址 ⇒ 必然连不上。
///   而 SideStore 那边（`Minimuxer`）**是把 `10.7.0.1` 写死**的，并没有做这种推导。
///   ⇒ 我不该自己发明这个机制（违反「目标工具没有的就不要有」）。
///
/// 现在的优先级（与 SideStore 对齐，两级）：
///   1. 用户显式覆盖：`UserDefaults["TunnelDeviceIP"]`（「设置 → 本地隧道」）
///   2. 兜底：`10.7.0.1`（LocalDevVPN 出厂 peerIP）
- (NSString *)_targetIP {
    NSString *deviceIP = [[[NSUserDefaults standardUserDefaults] stringForKey:@"TunnelDeviceIP"]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (deviceIP.length > 0) {
        return deviceIP;
    }
    return DEFAULT_TUNNEL_IP;
}

- (struct RpPairingFileHandle *)_loadPairingFile:(NSError **)error {
    NSString *path = self._pairingFileURL.path;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        if (error) *error = [self _error:@"Pairing file not found. Sideload TequilaDash with iPASide so it can place pairingFile.plist, or import one here." code:-17];
        return NULL;
    }
    struct RpPairingFileHandle *pf = NULL;
    struct IdeviceFfiError *err = rp_pairing_file_read(path.fileSystemRepresentation, &pf);
    if (err) {
        if (error) *error = [self _error:[NSString stringWithFormat:@"Failed to read pairing file: %s", err->message] code:err->code];
        idevice_error_free(err);
        return NULL;
    }
    return pf;
}

- (BOOL)_fillSockaddr:(struct sockaddr_in *)addr port:(uint16_t)port error:(NSError **)error {
    memset(addr, 0, sizeof(*addr));
    addr->sin_family = AF_INET;
    addr->sin_port = htons(port);
    NSString *deviceIP = [self _targetIP];
    if (inet_pton(AF_INET, deviceIP.UTF8String, &addr->sin_addr) != 1) {
        if (error) *error = [self _error:[NSString stringWithFormat:@"Failed to parse target IP address: %@", deviceIP] code:-18];
        return NO;
    }
    return YES;
}

- (BOOL)_createRpTunnel:(NSError **)error {
    struct RpPairingFileHandle *pairingFile = [self _loadPairingFile:error];
    if (!pairingFile) {
        return NO;
    }

    struct sockaddr_in addr;
    if (![self _fillSockaddr:&addr port:RPPPAIRING_PORT error:error]) {
        rp_pairing_file_free(pairingFile);
        return NO;
    }
    NSLog(@"[TequilaDash] RPPairing tunnel target %@:%d", [self _targetIP], RPPPAIRING_PORT);

    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    struct IdeviceFfiError *err = tunnel_create_rppairing(
        (const idevice_sockaddr *)&addr,
        (idevice_socklen_t)sizeof(addr),
        "TequilaDash",
        pairingFile,
        NULL,
        NULL,
        &adapter,
        &handshake
    );
    rp_pairing_file_free(pairingFile);

    if (err) {
        if (error) *error = [self _error:[NSString stringWithFormat:@"%s", err->message] code:err->code];
        idevice_error_free(err);
        if (handshake) rsd_handshake_free(handshake);
        if (adapter) adapter_free(adapter);
        return NO;
    }

    if (!adapter || !handshake) {
        if (handshake) rsd_handshake_free(handshake);
        if (adapter) adapter_free(adapter);
        if (error) *error = [self _error:@"Tunnel was created without valid handles." code:-1];
        return NO;
    }

    [self _freeTunnelHandles];
    _adapter = adapter;
    _handshake = handshake;
    return YES;
}

- (BOOL)_createClassicTunnel:(NSError **)error {
    NSString *path = self._pairingFileURL.path;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        if (error) *error = [self _error:@"Pairing file not found. Sideload TequilaDash with iPASide so it can place pairingFile.plist, or import one here." code:-17];
        return NO;
    }

    struct IdevicePairingFile *pf = NULL;
    struct IdeviceFfiError *err = idevice_pairing_file_read(path.fileSystemRepresentation, &pf);
    if (err) {
        if (error) *error = [self _error:[NSString stringWithFormat:@"Failed to read pairing file: %s", err->message] code:err->code];
        idevice_error_free(err);
        return NO;
    }

    NSLog(@"[TequilaDash] lockdown loopback target %@:%d", [self _targetIP], LOCKDOWN_PORT);

    __block IdeviceProviderHandle *provider = NULL;
    __block int hbCode = -1;
    __block NSString *hbMsg = nil;
    dispatch_semaphore_t firstBeat = dispatch_semaphore_create(0);
    int token = ++globalHeartbeatToken;

    __block BOOL firstCallback = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        startHeartbeat(pf, &provider, token, ^(int result, const char *message) {
            if (firstCallback) {
                firstCallback = NO;
                hbCode = result;
                hbMsg = message ? @(message) : nil;
                dispatch_semaphore_signal(firstBeat);
                return;
            }
            // 首拍之后的心跳死亡通知（heartbeat.m 在 marco/polo 失败与超时时回调）：
            // 必须把句柄清掉，否则 hasActiveTunnel 仍返回 YES、ensureHeartbeat 因「已有句柄」
            // 直接返回成功而不重建 —— 症状是「一直连着但所有操作都失败」，只能重启 App。
            if (result == 0) { return; }
            [self _providerDiedWithToken:token reason:(message ? @(message) : nil) code:result];
        });
    });

    // Lockdown 握手（TCP 62078 + pairing 校验）比 RPPairing 更慢；
    // 4s 会在正常设备上假超时。这里放宽到 30s，与 startHeartbeat 的外层预算一致。
    if (dispatch_semaphore_wait(firstBeat, dispatch_time(DISPATCH_TIME_NOW, (uint64_t)(30 * NSEC_PER_SEC))) != 0) {
        globalHeartbeatToken++;
        if (error) *error = [self _error:@"Timed out on the LocalDevVPN lockdown tunnel (30s). Enable LocalDevVPN and use a pairing file from iPASide or iLoader." code:-9];
        return NO;
    }
    if (hbCode != 0 || provider == NULL) {
        if (provider) { idevice_provider_free(provider); provider = NULL; }
        if (error) *error = [self _error:(hbMsg ?: @"Lockdown tunnel over LocalDevVPN failed.") code:hbCode];
        return NO;
    }

    // 换隧道时必须停掉旧心跳线程：旧 worker 唯一的退出信号是 globalHeartbeatToken.
    // 原先这里手写了一遍释放而漏掉 token++，导致每建一次 lockdown 隧道就多一条
    // 永不退出的心跳线程（对照 _freeTunnelHandles 的正确实现）。
    // 这里复用 _freeTunnelHandles —— 调用方本就在 _handleLock 内，递归锁允许嵌套。
    if (_provider == provider) {
        // 同一句柄重入：既不能释放它，也不能停掉正在服务它的心跳。
        return YES;
    }
    [self _freeTunnelHandles];
    _provider = provider;
    return YES;
}

- (BOOL)_createTunnel:(NSError **)error {
    NSError *rpErr = nil;
    if ([self _createRpTunnel:&rpErr]) {
        return YES;
    }
    NSError *classicErr = nil;
    if ([self _createClassicTunnel:&classicErr]) {
        return YES;
    }
    NSString *rpText = rpErr.localizedDescription ?: @"Remote Pairing did not connect";
    NSString *classicText = classicErr.localizedDescription ?: @"lockdown loopback did not connect";
    if (error) {
        *error = [self _error:[NSString stringWithFormat:@"%@ (iOS 26.4+ path). %@ (iOS 18 path). Enable LocalDevVPN on 10.7.0.1. The PC is not needed after the pairing file is placed.", rpText, classicText] code:-1];
    }
    return NO;
}

- (BOOL)startHeartbeat:(NSError **)error {
    // Only the worker can end an in-flight attempt. A caller timing out must
    // not release the gate and allow a second worker to overwrite its handles.
    os_unfair_lock_lock(&_tunnelLock);
    BOOL launch = !_tunnelConnecting;
    if (launch) {
        _tunnelConnecting = YES;
        _lastTunnelError = nil;
        _tunnelSemaphore = dispatch_semaphore_create(0);
    }
    dispatch_semaphore_t completionSem = _tunnelSemaphore;
    os_unfair_lock_unlock(&_tunnelLock);

    if (!launch) {
        // 已有建连在进行 ⇒ **立即返回**，不排队等。
        // v0.3.620：旧实现这里会 wait 最多 35s，而主界面每 3 秒重试一次，
        // 于是等待线程越堆越多 ⇒ 用户看到「一直卡在刷新中」。
        // 调用方拿到 -8 后自己退避重试即可。
        if (error) *error = [self _error:@"Tunnel is already connecting; retry shortly." code:-8];
        return NO;
    }

    if (launch) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            @autoreleasepool {
                NSError *createErr = nil;
                BOOL ok = NO;
                // 必须 @try/@finally：_createTunnel 内部任何一处 @throw 跳出时，
                // 若跳过下面的 _tunnelConnecting = NO，闸门就永久卡在 YES ——
                // 此后所有调用都走 -8（建连中，快速失败），只能重启 App 才能恢复。
                @try {
                    [self->_handleLock lock];
                    ok = [self _createTunnel:&createErr];
                    [self->_handleLock unlock];
                } @catch (NSException *ex) {
                    ok = NO;
                    createErr = [self _error:[NSString stringWithFormat:@"建连时抛出异常：%@（%@）",
                        ex.reason ?: @"", ex.name ?: @""]
                                        code:-1];
                } @finally {
                    os_unfair_lock_lock(&self->_tunnelLock);
                    self->_lastTunnelError = ok ? nil :
                        (createErr ?: [self _error:@"Failed to connect over LocalDevVPN." code:-1]);
                    self->_tunnelConnecting = NO;
                    self->_tunnelSemaphore = NULL;
                    os_unfair_lock_unlock(&self->_tunnelLock);
                    dispatch_semaphore_signal(completionSem);
                }
            }
        });
    }

    // RP initial TCP + pair verify + the 18s listener budget exceed 4 seconds.
    intptr_t timedOut = dispatch_semaphore_wait(completionSem,
        dispatch_time(DISPATCH_TIME_NOW, (uint64_t)(35 * NSEC_PER_SEC)));
    if (timedOut) {
        if (error) *error = [self _error:@"Tunnel connection is still in progress (35s); no duplicate handshake was started." code:-9];
        return NO;
    }
    // Pass the completion signal to other callers waiting on this attempt.
    dispatch_semaphore_signal(completionSem);
    os_unfair_lock_lock(&_tunnelLock);
    NSError *resultError = _lastTunnelError;
    os_unfair_lock_unlock(&_tunnelLock);
    if (error) *error = resultError;
    return resultError == nil;
}

- (BOOL)ensureHeartbeatWithError:(NSError **)error {
    [_handleLock lock];
    BOOL up = [self _hasUsableHandlesLocked];
    [_handleLock unlock];
    if (up) {
        return YES;
    }
    return [self startHeartbeat:error];
}

- (NSDictionary<NSString *, NSDictionary *> *)getAllAppsInfoWithError:(NSError **)error {
    if ([self _rejectIfConnectingWithError:error]) return nil;
    // 句柄与 FFI 调用整体串行：Rust 侧的 adapter/handshake 不是为并发复用设计的，
    // 并发访问会让同一 _adapter 同时被 &mut 借用（UB）。
    [_handleLock lock];
    @try {
        if (_adapter && _handshake) {
            NSString *errStr = nil;
            NSDictionary *apps = getAllAppsInfo(_adapter, _handshake, &errStr);
            if (errStr) {
                if (error) *error = [self _error:errStr code:-17];
                return nil;
            }
            return (NSDictionary<NSString *, NSDictionary *> *)apps;
        }
        if (_provider) {
            NSString *errStr = nil;
            NSDictionary *apps = getAllAppsInfoFromProvider(_provider, &errStr);
            if (errStr) {
                if (error) *error = [self _error:errStr code:-17];
                return nil;
            }
            return (NSDictionary<NSString *, NSDictionary *> *)apps;
        }
        if (error) *error = [self _error:@"Tunnel not connected. Start heartbeat first." code:-1];
        return nil;
    } @finally {
        [_handleLock unlock];
    }
}

- (UIImage *)getAppIconWithBundleId:(NSString *)bundleId error:(NSError **)error {
    if ([self _rejectIfConnectingWithError:error]) return nil;
    [_handleLock lock];
    @try {
        if (_adapter && _handshake) {
            NSString *errStr = nil;
            UIImage *icon = getAppIcon(_adapter, _handshake, bundleId, &errStr);
            if (errStr) {
                if (error) *error = [self _error:errStr code:-17];
                return nil;
            }
            return icon;
        }
        if (_provider) {
            NSString *errStr = nil;
            UIImage *icon = getAppIconFromProvider(_provider, bundleId, &errStr);
            if (errStr) {
                if (error) *error = [self _error:errStr code:-17];
                return nil;
            }
            return icon;
        }
        if (error) *error = [self _error:@"Tunnel not connected." code:-1];
        return nil;
    } @finally {
        [_handleLock unlock];
    }
}

- (BOOL)uninstallAppWithBundleId:(NSString *)bundleId error:(NSError **)error {
    if (!bundleId || bundleId.length == 0) {
        if (error) *error = [self _error:@"Bundle identifier is empty." code:-1];
        return NO;
    }
    // Make sure the pairing-file + LocalDevVPN tunnel is up.
    if (![self ensureHeartbeatWithError:error]) {
        return NO;
    }
    [_handleLock lock];
    @try {
        if (_adapter && _handshake) {
            NSString *errStr = nil;
            BOOL ok = uninstall_app(_adapter, _handshake, bundleId, &errStr);
            if (!ok && error) {
                *error = [self _error:(errStr ?: @"Uninstall over RPPairing tunnel failed.") code:-17];
            }
            return ok;
        }
        if (_provider) {
            NSString *errStr = nil;
            BOOL ok = uninstall_app_from_provider(_provider, bundleId, &errStr);
            if (!ok && error) {
                *error = [self _error:(errStr ?: @"Uninstall over lockdown tunnel failed.") code:-17];
            }
            return ok;
        }
        if (error) *error = [self _error:@"Tunnel not connected. Import a pairing file and enable LocalDevVPN." code:-1];
        return NO;
    } @finally {
        [_handleLock unlock];
    }
}

- (void)dealloc {
    [_handleLock lock];
    [self _freeTunnelHandles];
    [_handleLock unlock];
}

@end
