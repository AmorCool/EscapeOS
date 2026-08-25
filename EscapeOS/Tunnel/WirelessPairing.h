//
//  WirelessPairing.h
//  EscapeOS
//
//  iOS 27 device-initiated wireless pairing host wrapper.
//  Bridges si_run_host() (Rust) to SwiftUI: publishes the
//  _remotepairing-pairable-host._tcp Bonjour service and surfaces the
//  6-digit setup PIN and final result via NSNotificationCenter.
//
//  Why notifications instead of completion blocks?
//  Swift's Clang Importer silently drops bridged methods that have block
//  parameters; we route progress through NotificationCenter (no block params
//  in the bridged surface, so the startPairing method imports cleanly).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the MAIN queue right after the 6-digit setup PIN is generated.
/// `userInfo[@"pin"]` is an NSString of digits.
extern NSNotificationName const WirelessPairingDidShowPINNotification;

/// Posted on the MAIN queue when the engine finishes (success or failure).
/// `userInfo` keys:
///   @"success"    : NSNumber<BOOL>
///   @"deviceName" : NSString (empty when nil)
///   @"hostAltIrk" : NSString (empty when nil / first pairing)
///   @"error"      : NSString (empty when nil)
extern NSNotificationName const WirelessPairingDidCompleteNotification;

@interface WirelessPairing : NSObject

/// Starts iOS 27 device-initiated wireless pairing. Returns immediately; the
/// actual work runs on a background queue and reports progress via the
/// notifications declared above. Call `-stop` to halt.
/// @param hostName      Name shown on the device (e.g. "EscapeOS").
/// @param model         Hardware model shown on the device (e.g. "Mac17,7").
/// @param outPath       Path where the resulting RpPairingFile is written.
/// @param storedAltIrk  Previously returned host_alt_irk_hex, or "" for first pairing.
- (void)startPairingWithHostName:(NSString *)hostName
                            model:(NSString *)model
                          outPath:(NSString *)outPath
                     storedAltIrk:(NSString *)storedAltIrk;

- (void)stop;

@end

NS_ASSUME_NONNULL_END