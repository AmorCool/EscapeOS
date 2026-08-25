//
//  WirelessPairing.h
//  EscapeOS
//
//  iOS 27 device-initiated wireless pairing host wrapper.
//  Bridges si_run_host() (Rust) to SwiftUI: publishes the
//  _remotepairing-pairable-host._tcp Bonjour service and surfaces the
//  6-digit setup PIN for in-app display.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WirelessPairing : NSObject

/// Starts iOS 27 device-initiated wireless pairing. The call blocks internally
/// on a background queue, so this method returns immediately.
/// @param hostName      Name shown on the device (e.g. "EscapeOS").
/// @param model         Hardware model shown on the device (keep a Mac id, e.g. "Mac17,7").
/// @param outPath       Path where the resulting RpPairingFile is written.
/// @param storedAltIrk  Previously returned host_alt_irk_hex, or "" for first pairing.
/// @param pinHandler    Called on the main queue with the 6-digit PIN to show.
/// @param completion    Called on the main queue with the final result.
- (void)startPairingWithHostName:(NSString *)hostName
                            model:(NSString *)model
                          outPath:(NSString *)outPath
                     storedAltIrk:(NSString *)storedAltIrk
                      pinHandler:(void (^)(NSString *pin))pinHandler
                       completion:(void (^)(BOOL success,
                                            NSString *deviceName,
                                            NSString *hostAltIrk,
                                            NSString *error))completion;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
