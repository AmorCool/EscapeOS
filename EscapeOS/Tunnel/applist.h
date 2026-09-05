//
//  applist.h
//  EscapeOS
//
//  InstallationProxy / SpringBoard helpers over an RPPairing RSD tunnel.
//

#ifndef APPLIST_H
#define APPLIST_H
@import Foundation;
@import UIKit;
#include "idevice.h"

NSDictionary<NSString*, NSString*>* list_installed_apps(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString** error);
NSDictionary<NSString*, NSString*>* list_all_apps(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString** error);
NSDictionary<NSString*, NSString*>* list_hidden_system_apps(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString** error);
UIImage* getAppIcon(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString* bundleID, NSString** error);

NSDictionary *getAllAppsInfo(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString **error);
NSDictionary *getAllAppsInfoFromProvider(struct IdeviceProviderHandle *provider, NSString **error);
UIImage *getAppIconFromProvider(struct IdeviceProviderHandle *provider, NSString *bundleID, NSString **error);
id plist_to_objc_object(plist_t plist);

/// Uninstall a user app through the RPPairing/RSD tunnel. The pairing file
/// authenticates the operation with `installd`, so no in-process
/// `com.apple.private.mobileinstallation.allow-uninstall` entitlement is
/// needed. Returns YES on success; on failure fills `error` and returns NO.
BOOL uninstall_app(struct AdapterHandle *adapter, struct RsdHandshakeHandle *handshake, NSString *bundleID, NSString **error);

/// Same as `uninstall_app`, but over the classic lockdown tunnel (iOS 18).
BOOL uninstall_app_from_provider(struct IdeviceProviderHandle *provider, NSString *bundleID, NSString **error);

#endif /* APPLIST_H */
