//
//  WirelessPairing.m
//  EscapeOS
//

#import "WirelessPairing.h"
#import "si_pairing.h"
#import <dns_sd.h>

NSNotificationName const WirelessPairingDidShowPINNotification = @"WirelessPairingDidShowPINNotification";
NSNotificationName const WirelessPairingDidCompleteNotification = @"WirelessPairingDidCompleteNotification";

@interface WirelessPairing () <NSNetServiceDelegate>
@property (nonatomic, strong, nullable) NSNetService *netService;
@property (nonatomic, strong, nullable) NSTimer *keepAliveTimer;
@property (nonatomic, assign) uint16_t listenPort;
@property (nonatomic, copy, nullable) NSString *serviceDisplayName;
@property (nonatomic, copy, nullable) NSDictionary<NSString *,NSString *> *serviceTxt;
@property (nonatomic, copy, nullable) void (^pinHandler)(NSString *pin);
@property (nonatomic, copy, nullable) void (^completion)(BOOL, NSString *, NSString *, NSString *);
@end

@implementation WirelessPairing

- (void)startPairingWithHostName:(NSString *)hostName
                           model:(NSString *)model
                         outPath:(NSString *)outPath
                     storedAltIrk:(NSString *)storedAltIrk {
    if (hostName.length == 0) hostName = @"EscapeOS";
    if (model.length == 0) model = @"Mac17,7";

    // Keep `self` alive for the whole blocking call.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        SiPairResult result;
        memset(&result, 0, sizeof(result));
        const char *hostAltIrkC = storedAltIrk.UTF8String;
        int rc = si_run_host("0.0.0.0", 0,
                            hostName.UTF8String, model.UTF8String,
                            outPath.UTF8String,
                            hostAltIrkC && *hostAltIrkC ? hostAltIrkC : "",
                            si_ready_cb, si_pin_cb, (__bridge void *)strongSelf,
                            &result);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) s2 = weakSelf;
            if (!s2) return;
            [s2 stopAdvertising];

            NSMutableDictionary<NSString *, id> *info = [NSMutableDictionary new];
            info[@"success"] = @(rc == 0);
            if (rc == 0) {
                info[@"deviceName"] = result.device_name ? [NSString stringWithUTF8String:result.device_name] : @"";
                info[@"hostAltIrk"] = result.host_alt_irk_hex ? [NSString stringWithUTF8String:result.host_alt_irk_hex] : @"";
                info[@"error"] = @"";
            } else {
                info[@"deviceName"] = @"";
                info[@"hostAltIrk"] = @"";
                info[@"error"] = result.error ? [NSString stringWithUTF8String:result.error] : @"未知错误";
            }
            si_result_free(&result);
            [[NSNotificationCenter defaultCenter]
                postNotificationName:WirelessPairingDidCompleteNotification
                              object:s2 userInfo:info];
        });
    });
}

- (void)stop {
    [self stopAdvertising];
}

#pragma mark - C callbacks

static void si_ready_cb(void *ctx, const char *service_id, uint16_t port,
                        const char **txt_keys, const char **txt_vals, size_t txt_count) {
    WirelessPairing *self = (__bridge WirelessPairing *)ctx;
    // The Bluetooth-style pairing manifest shown in iOS Settings → Developer
    // Mode → Pairing Devices reads its label from the Bonjour service instance
    // name, not from the underlying service_id (which is a UUID). Use a
    // readable "EscapePair-<6 chars>" label so the device can identify us
    // among multiple hosts (StikPair, iloader, etc.). The trailing 6 hex chars
    // are the *service_id*'s last 6 hex chars — they are stable per host, so a
    // user with two EscapeOS phones will see distinct labels.
    NSString *sidRaw = service_id ? [NSString stringWithUTF8String:service_id] : @"unknown";
    NSString *suffix = sidRaw.length >= 6
        ? [sidRaw substringFromIndex:sidRaw.length - 6]
        : sidRaw;
    NSString *displayName = [NSString stringWithFormat:@"EscapePair-%@", suffix];
    NSMutableDictionary<NSString *,NSString *> *txt = [NSMutableDictionary new];
    for (size_t i = 0; i < txt_count; i++) {
        NSString *k = (txt_keys && txt_keys[i]) ? [NSString stringWithUTF8String:txt_keys[i]] : nil;
        NSString *v = (txt_vals && txt_vals[i]) ? [NSString stringWithUTF8String:txt_vals[i]] : nil;
        if (k && v) txt[k] = v;
    }

    // Publish on the main runloop asynchronously so the worker thread
    // (which holds the TcpListener accept()) is NOT blocked on a delegate
    // callback. iOS 18 will sometimes not invoke `netServiceDidPublish:`
    // for minutes — the legacy 15s semaphore caused the Rust accept to
    // never get a connection slot. The NSTimer below keeps the registration
    // alive on a 30s heartbeat so the device-side browse stays open.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self publishServiceWithName:displayName port:port txt:txt];
        // Heartbeat: drop + re-publish every 30s. NSNetService's internal
        // DNSServiceRegister refreshes at ~120s, but on iOS 18 ad-hoc
        // services often get auto-collected by the system's "stale service"
        // sweeper; a forced stop+publish resets the SRP timer.
        self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:30
                                                               repeats:YES
                                                                 block:^(NSTimer *t) {
            if (!self.serviceDisplayName) {
                [t invalidate];
                return;
            }
            NSLog(@"[WirelessPairing] heartbeat republish port=%u name=%@",
                  self.listenPort, self.serviceDisplayName);
            [self publishServiceWithName:self.serviceDisplayName
                                     port:self.listenPort
                                      txt:self.serviceTxt];
        }];
    });
}

static void si_pin_cb(const char *pin, void *ctx) {
    WirelessPairing *self = (__bridge WirelessPairing *)ctx;
    NSString *p = pin ? [NSString stringWithUTF8String:pin] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:WirelessPairingDidShowPINNotification
                          object:self
                        userInfo:@{@"pin": p}];
    });
}

#pragma mark - Bonjour

- (void)publishServiceWithName:(NSString *)serviceName port:(uint16_t)port txt:(NSDictionary<NSString *,NSString *> *)txt {
    [self stopAdvertising];
    self.listenPort = port;
    self.serviceDisplayName = serviceName;
    self.serviceTxt = txt;
    NSLog(@"[WirelessPairing] publish begin name=%@ port=%u txt_keys=%lu",
          serviceName, port, (unsigned long)txt.count);
    self.netService = [[NSNetService alloc] initWithDomain:@""
                                                     type:@"_remotepairing-pairable-host._tcp"
                                                     name:serviceName
                                                     port:port];
    NSMutableDictionary *txtData = [NSMutableDictionary new];
    for (NSString *k in txt) {
        txtData[k] = [txt[k] dataUsingEncoding:NSUTF8StringEncoding];
    }
    [self.netService setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:txtData]];
    self.netService.delegate = self;
    [self.netService publish];
}

- (void)stopAdvertising {
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
    }
    self.serviceDisplayName = nil;
    self.serviceTxt = nil;
    if (self.netService) {
        NSLog(@"[WirelessPairing] stopAdvertising (name=%@)", self.netService.name);
        self.netService.delegate = nil;
        [self.netService stop];
        self.netService = nil;
    }
}

#pragma mark - NSNetServiceDelegate

- (void)netServiceDidPublish:(NSNetService *)sender {
    NSLog(@"[WirelessPairing] netServiceDidPublish name=%@ port=%u",
          sender.name, (unsigned)sender.port);
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *,NSNumber *> *)errorDict {
    NSLog(@"[WirelessPairing] didNotPublish errorDict=%@", errorDict);
}

@end
