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
@property (nonatomic, strong, nullable) dispatch_semaphore_t publishSem;
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
    NSString *sid = service_id ? [NSString stringWithUTF8String:service_id] : @"escapeos";
    NSMutableDictionary<NSString *,NSString *> *txt = [NSMutableDictionary new];
    for (size_t i = 0; i < txt_count; i++) {
        NSString *k = (txt_keys && txt_keys[i]) ? [NSString stringWithUTF8String:txt_keys[i]] : nil;
        NSString *v = (txt_vals && txt_vals[i]) ? [NSString stringWithUTF8String:txt_vals[i]] : nil;
        if (k && v) txt[k] = v;
    }

    // Publish on the main runloop, then block this (worker) thread until the
    // delegate reports publish success/failure so the device can actually find us.
    self.publishSem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self publishServiceWithID:sid port:port txt:txt];
    });
    dispatch_semaphore_wait(self.publishSem,
                           dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    // (publish outcome is reflected in the published NSNetService; no Swift
    //  notification needed for "ready".)
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

- (void)publishServiceWithID:(NSString *)serviceID port:(uint16_t)port txt:(NSDictionary<NSString *,NSString *> *)txt {
    [self stopAdvertising];
    self.netService = [[NSNetService alloc] initWithDomain:@""
                                                     type:@"_remotepairing-pairable-host._tcp"
                                                     name:serviceID
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
    if (self.netService) {
        self.netService.delegate = nil;
        [self.netService stop];
        self.netService = nil;
    }
    if (self.publishSem) {
        dispatch_semaphore_signal(self.publishSem);
        self.publishSem = nil;
    }
}

#pragma mark - NSNetServiceDelegate

- (void)netServiceDidPublish:(NSNetService *)sender {
    if (self.publishSem) {
        dispatch_semaphore_signal(self.publishSem);
        self.publishSem = nil;
    }
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *,NSNumber *> *)errorDict {
    if (self.publishSem) {
        dispatch_semaphore_signal(self.publishSem);
        self.publishSem = nil;
    }
}

@end
