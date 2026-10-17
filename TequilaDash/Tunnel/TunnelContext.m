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
// v0.3.636：建连改为多候选，候选来源之一是路由表枚举（C 垫片）。
#import "EscRoutePeers.h"

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

/// **只读**：配对文件能否被 RPPairing 解析（v0.3.639 新增）.
///
/// `hasPairingFile` 只查文件存在性；本属性做一次**纯内存解析**：
/// 读文件 → `rp_pairing_file_read` → 立刻 free。
/// 不建套接字、不碰隧道状态，符合「诊断只读」纪律。
- (BOOL)isPairingFileParsable {
    return [self _pairingParseProbe] == nil;
}

/// **只读**：配对文件解析失败原因.
- (NSString *)pairingFileParseError {
    return [self _pairingParseProbe];
}

/// 解析探针：成功返回 nil，失败返回原因描述.
///
/// 抽成私有方法是为了让上面两个属性共用同一次解析结果语义
/// （诊断页会连着读两次）。
- (NSString *)_pairingParseProbe {
    NSString *path = self._pairingFileURL.path;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return @"配对文件不存在";
    }
    struct RpPairingFileHandle *pf = NULL;
    struct IdeviceFfiError *err = rp_pairing_file_read(path.fileSystemRepresentation, &pf);
    if (err) {
        NSString *msg = [NSString stringWithFormat:@"%s (code %d)", err->message, err->code];
        idevice_error_free(err);
        if (pf) rp_pairing_file_free(pf);
        return msg;
    }
    if (pf) rp_pairing_file_free(pf);
    return nil;
}

/// **只读**：最近一次建连失败原因（v0.3.639 新增）.
///
/// 与 `isConnecting` 完全同款：只读已有 ivar、**不建连、不改状态**。
/// 诊断页靠它把「为什么连不上」显示出来 —— 在此之前，
/// 诊断页只能看到现象（不可达 / 未建立），永远拿不到真实原因。
- (NSError *)lastTunnelError {
    os_unfair_lock_lock(&_tunnelLock);
    NSError *e = _lastTunnelError;
    os_unfair_lock_unlock(&_tunnelLock);
    return e;
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

    // v0.3.636：**多候选尝试**。
    //
    // 原先只用 `_targetIP`（单个地址，通常写死 10.7.0.1）建隧道。而真机上
    // LocalDevVPN 的对端**并不总是 10.7.0.1** —— 用户改过设置、或系统给的 utun
    // 对端在别的网段时，单地址必然连不上。
    //
    // 诊断页与就绪判定早就在用多候选（LocalDevVPN.candidateTunnelPeers），
    // 但**建连路径一直只用单值** —— 这是「预检说通、真连就断」的结构性原因。
    //
    // 现在按「上次成功 → 用户覆盖 → utun/路由表 → 10.7.0.1」逐个尝试，
    // 第一个成功的即采用。
    NSArray<NSString *> *candidates = [self _candidateTunnelPeers];
    if (candidates.count == 0) {
        rp_pairing_file_free(pairingFile);
        if (error) *error = [self _error:@"No tunnel peer candidates (LocalDevVPN may not be connected)." code:-19];
        return NO;
    }

    NSError *lastError = nil;
    NSUInteger candidateIndex = 0;
    for (NSString *peer in candidates) {
        candidateIndex++;
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(RPPPAIRING_PORT);
        if (inet_pton(AF_INET, peer.UTF8String, &addr.sin_addr) != 1) {
            continue;   // 非法 IP 直接跳过（不静默连 0.0.0.0）
        }
        NSLog(@"[TequilaDash] RPPairing tunnel trying %@:%d (%lu/%lu)",
              peer, RPPPAIRING_PORT,
              (unsigned long)candidateIndex, (unsigned long)candidates.count);

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

        if (err) {
            lastError = [self _error:[NSString stringWithFormat:@"%s", err->message] code:err->code];
            NSLog(@"[TequilaDash] RPPairing tunnel failed on %@: %s (code %d)",
                  peer, err->message, err->code);
            idevice_error_free(err);
            if (handshake) rsd_handshake_free(handshake);
            if (adapter) adapter_free(adapter);
            continue;
        }

        if (!adapter || !handshake) {
            if (handshake) rsd_handshake_free(handshake);
            if (adapter) adapter_free(adapter);
            lastError = [self _error:@"Tunnel was created without valid handles." code:-1];
            continue;
        }

        // 成功：记住这个候选，后续建连优先用它
        [self _rememberWorkingPeer:peer];
        rp_pairing_file_free(pairingFile);
        [self _freeTunnelHandles];
        _adapter = adapter;
        _handshake = handshake;
        NSLog(@"[TequilaDash] RPPairing tunnel established on %@", peer);
        return YES;
    }

    rp_pairing_file_free(pairingFile);
    if (error) {
        *error = lastError ?: [self _error:@"All tunnel peer candidates failed." code:-1];
    }
    return NO;
}

/// 本次要依次尝试的候选对端（v0.3.636 新增）。
///
/// 顺序与 Swift 侧 `LocalDevVPN.candidateTunnelPeers()` 对齐：
///   1. 上次成功的那个（若有）—— 命中率最高，放最前
///   2. 用户显式覆盖 `TunnelDeviceIP`
///   3. utun 点对点对端 + 路由表枚举（`esc_route_utun_peers`）
///   4. 兜底 10.7.0.1
///
/// 去重后返回。拿不到路由表就只用前两级，不影响建连。
- (NSArray<NSString *> *)_candidateTunnelPeers {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^add)(NSString *) = ^(NSString *ip) {
        if (ip.length == 0) return;
        struct in_addr probe;
        if (inet_pton(AF_INET, ip.UTF8String, &probe) != 1) return;   // 非法 IP 不收
        if ([seen containsObject:ip]) return;
        [seen addObject:ip];
        [out addObject:ip];
    };

    // 1. 上次成功的
    NSString *lastGood = [[NSUserDefaults standardUserDefaults] stringForKey:@"TunnelLastGoodPeer"];
    if (lastGood.length > 0) add(lastGood);

    // 2. 用户覆盖
    add([self _targetIP]);

    // 3. utun 点对点对端 + 路由表（C 垫片，失败返回 NULL）
    size_t peerCount = 0;
    char *peers = esc_route_utun_peers(&peerCount);
    if (peers) {
        NSString *joined = [NSString stringWithUTF8String:peers];
        esc_route_utun_peers_free(peers);
        for (NSString *part in [joined componentsSeparatedByString:@","]) {
            add([part stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        }
    }

    // 4. 兜底
    add(DEFAULT_TUNNEL_IP);

    return out;
}

/// 记住建连成功的对端，下次优先用它。
- (void)_rememberWorkingPeer:(NSString *)peer {
    if (peer.length == 0) return;
    [[NSUserDefaults standardUserDefaults] setObject:peer forKey:@"TunnelLastGoodPeer"];
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

    // ⚠️⚠️ 这里**不能**调 `_freeTunnelHandles`（v0.3.635 修复 v0.3.621 引入的致命回归）。
    //
    // `globalHeartbeatToken` 承担了**两个互斥语义**：
    //   A. 「有更新的心跳 worker 启动了吗」—— 只应由 startHeartbeat 侧的 `++globalHeartbeatToken` 推进；
    //   B. 「句柄要释放，让旧 worker 退出」—— 由 _freeTunnelHandles 自增。
    //
    // 我 v0.3.621 把这里从「手写释放」改成复用 `_freeTunnelHandles`，本意是补上漏掉的
    // token++（避免旧心跳线程永不退出）。**但调用时机错了**：
    // 此时 `startHeartbeat` 已经成功、`provider` 已就绪，token 是 N；
    // 调 `_freeTunnelHandles` 会把它推到 N+1 ⇒ 下一轮 marco 返回后
    // heartbeat.m:107 的 `heartbeatToken != globalHeartbeatToken` 命中 ⇒ **刚建好的心跳线程自杀**。
    //
    // 后果链：
    //   心跳线程退出 → 设备侧 62078 连接被对端回收 → 后续 FFI 全部断连；
    //   且 heartbeat.m:97/121/135 的失败回调也被同一个 token 判定挡掉（永不成立）
    //   ⇒ `_lastTunnelError` 拿不到真实原因 ⇒ 用户看到「完全连不上、也没有原因」；
    //   而 `_hasUsableHandlesLocked` 只看 `_provider != NULL`，心跳死了它仍返回 YES
    //   ⇒ `ensureHeartbeat` 直接 return YES **不重建** ⇒ 闭环死锁，只能重启 App。
    //
    // 正确做法：这里只释放**旧**句柄，**不动 token**。
    // 「停掉旧心跳线程」已由本函数入口处的 `int token = ++globalHeartbeatToken;` 完成。
    if (_provider == provider) {
        // 同一句柄重入：既不释放，也不停心跳。
        return YES;
    }
    if (_handshake) { rsd_handshake_free(_handshake); _handshake = NULL; }
    if (_adapter) { adapter_free(_adapter); _adapter = NULL; }
    if (_provider && _provider != provider) { idevice_provider_free(_provider); }
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
