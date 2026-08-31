TARGET = iphone:clang:16.5:18.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = EscapeSpace

# iOS 26 系统特性（原生玻璃效果等）需要 macOS 上的 Xcode 26 —— 见 docs/BUILD.md。
# WSL/Theos uses iPhoneOS16.5.sdk because Apple SDK 18+/26+ needs Apple Clang, not Linux clang.

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = EscapeSpace

EscapeSpace_FILES = \
	EscapeOS/EscapeOSApp.swift \
	EscapeOS/Views/RootView.swift \
	EscapeOS/Views/AppListView.swift \
	EscapeOS/Views/AppDetailView.swift \
	EscapeOS/Views/FileBrowserView.swift \
	EscapeOS/Views/FileBrowserViewModel.swift \
	EscapeOS/Views/FileRow.swift \
	EscapeOS/Views/FileViewerView.swift \
	EscapeOS/Views/HexEditorView.swift \
	EscapeOS/Views/FilePropertiesView.swift \
	EscapeOS/Views/BackupView.swift \
	EscapeOS/Views/BackupsListView.swift \
	EscapeOS/Views/LimitsDisclaimer.swift \
	EscapeOS/Views/ReclaimAppView.swift \
	EscapeOS/Views/ReclaimTabView.swift \
	EscapeOS/Views/LiveCleanTabView.swift \
	EscapeOS/Views/SpaceReclaimView.swift \
	EscapeOS/Views/MoreView.swift \
	EscapeOS/Views/DeviceControlView.swift \
	EscapeOS/Views/IncreaseMemoryView.swift \
	EscapeOS/Views/ConfigurationsView.swift \
	EscapeOS/Views/RespringView.swift \
	EscapeOS/Views/AppleIDLoginSheet.swift \
	EscapeOS/Views/PairingFilePicker.swift \
	EscapeOS/Views/SharedDocumentPicker.swift \
	EscapeOS/Views/DDIDownloadView.swift \
	EscapeOS/Views/DomainBlockerView.swift \
	EscapeOS/Views/DesignSystem.swift \
	EscapeOS/Views/JITEnableView.swift \
	EscapeOS/Views/LaunchAppsView.swift \
	EscapeOS/Views/AppExpiryView.swift \
	EscapeOS/Views/CertificateView.swift \
	EscapeOS/Views/PairingInstallView.swift \
	EscapeOS/Views/IPAInstallView.swift \
	EscapeOS/Views/ProcessManagerView.swift \
	EscapeOS/Views/Supervised/SupervisedHelpers.swift \
	EscapeOS/Views/Supervised/RestrictionTweaksView.swift \
	EscapeOS/Views/Supervised/AppHideView.swift \
	EscapeOS/Views/Supervised/NotificationManageView.swift \
	EscapeOS/Views/Supervised/WebClipView.swift \
	EscapeOS/Views/Supervised/SupervisedFootnoteView.swift \
	EscapeOS/Views/Wallpaper/WallpaperModels.swift \
	EscapeOS/Views/Wallpaper/WallpaperHandler.swift \
	EscapeOS/Views/Wallpaper/WallpaperView.swift \
	EscapeOS/Views/DialerTheme/DialerThemeManager.swift \
	EscapeOS/Views/DialerTheme/DialerThemeView.swift \
	EscapeOS/Views/FileBrowserRootView.swift \
	EscapeOS/Views/AFCBrowserView.swift \
	EscapeOS/Views/CrashLogView.swift \
	EscapeOS/Views/IPCCInstallView.swift \
	EscapeOS/Views/SignedIPAInstallView.swift \
	EscapeOS/Views/KernelCacheView.swift \
	EscapeOS/Views/ProfileInstallView.swift \
	EscapeOS/Views/RingtonesView.swift \
	EscapeOS/Views/PlistEditor/PlistEditorModels.swift \
	EscapeOS/Views/PlistEditor/PlistEditorViewModel.swift \
	EscapeOS/Views/PlistEditor/PlistEditorView.swift \
	EscapeOS/Views/PlistEditor/PlistModifyView.swift \
	EscapeOS/Views/VirtualLocation/Theme.swift \
	EscapeOS/Views/VirtualLocation/MapDropPin.swift \
	EscapeOS/Views/VirtualLocation/JoystickPad.swift \
	EscapeOS/Views/VirtualLocation/RoutePlannerSheet.swift \
	EscapeOS/Views/VirtualLocation/MapHomeView.swift \
	EscapeOS/Views/VirtualLocation/VirtualLocationView.swift \
	EscapeOS/Views/VirtualLocation/VirtualLocationSettingsView.swift \
	EscapeOS/Views/VirtualLocation/PlacesView.swift \
	EscapeOS/Engine/ZipReader.swift \
	EscapeOS/Engine/BackupPaths.swift \
	EscapeOS/Engine/RestoreService.swift \
	EscapeOS/Engine/SandboxEscape.swift \
	EscapeOS/Engine/BadQueryLister.swift \
	EscapeOS/Engine/ContainerNameResolver.swift \
	EscapeOS/Engine/FileSystemRoots.swift \
	EscapeOS/Engine/DeviceControlService.swift \
	EscapeOS/Engine/AFCService.swift \
	EscapeOS/Engine/CrashLogService.swift \
	EscapeOS/Engine/IPCCInstallService.swift \
	EscapeOS/Engine/KernelCacheService.swift \
	EscapeOS/Engine/RingtonesService.swift \
	EscapeOS/Engine/FileKind.swift \
	EscapeOS/Engine/FileClipboard.swift \
	EscapeOS/Engine/FileService.swift \
	EscapeOS/Engine/ProfileHTTPServer.swift \
	EscapeOS/Engine/SupervisedProfileStore.swift \
	EscapeOS/Engine/AppDiscovery.swift \
	EscapeOS/Engine/BackupService.swift \
	EscapeOS/Engine/ZipWriter.swift \
	EscapeOS/Engine/ZipPassword.swift \
	EscapeOS/Engine/SevenZipAES.swift \
	EscapeOS/Engine/ArchiveExtractor.swift \
	EscapeOS/Engine/ReclaimService.swift \
	EscapeOS/Engine/LiveContainerDiscovery.swift \
	EscapeOS/Engine/UninstallService.swift \
	EscapeOS/Engine/LocationEngine.swift \
	EscapeOS/Engine/ChinaCoordinateTransform.swift \
	EscapeOS/Engine/BackgroundKeepAlive.swift \
	EscapeOS/Engine/SavedPlace.swift \
	EscapeOS/Engine/LocalDevVPN.swift \
	EscapeOS/Engine/RouteBuilder.swift \
	EscapeOS/Engine/KeepAliveManager.swift \
	EscapeOS/Engine/SpoofSession.swift \
	EscapeOS/Engine/JITEnableService.swift \
	EscapeOS/Engine/ProvisioningProfileStore.swift \
	EscapeOS/Engine/CertificateManager.swift \
	EscapeOS/Engine/PairingInstallService.swift \
	EscapeOS/Engine/IPAInstallService.swift \
	EscapeOS/Engine/TwoFactorPromptCoordinator.swift \
	EscapeOS/Engine/zip_crypto.c \
	EscapeOS/Engine/bad_query.c \
	EscapeOS/Engine/MCM/MCMBridge.m \
	EscapeOS/Engine/MCM/BQMCMIntegration.m \
	EscapeOS/Engine/MCM/GestaltEngine.swift \
	EscapeOS/Engine/MCM/MCMIntegration.swift \
	EscapeOS/Views/GestaltView.swift \
	EscapeOS/Tunnel/TunnelContext.m \
	EscapeOS/Tunnel/applist.m \
	EscapeOS/Tunnel/heartbeat.m \
	EscapeOS/Tunnel/WirelessPairing.m \
	EscapeOS/Services/BackgroundAudioManager.swift \
	EscapeOS/Services/BackgroundLocationManager.swift \
	EscapeOS/Services/WirelessKeepAlive.swift \
	EscapeOS/Services/MemoryLimitSettings.swift \
	EscapeOS/Services/AppleAuth/BigInt.swift \
	EscapeOS/Services/AppleAuth/SRP6a.swift \
	EscapeOS/Services/AppleAuth/AppleAuthModels.swift \
	EscapeOS/Services/AppleAuth/GSAAuth.swift \
	EscapeOS/Services/AppleAuth/AnisetteProvider.swift \
	EscapeOS/Services/AppleAuth/AppleAuthenticator.swift \
	EscapeOS/Services/AppleAuth/LoginLogger.swift \
	EscapeOS/Services/AppleAuth/AppleDeveloperAPI.swift

EscapeSpace_FILES += $(shell find vendor/BitByteData/Sources vendor/SWCompression/Sources -name '*.swift' \
	! -name 'TarWriter.swift' ! -name 'TarReader.swift' ! -name 'TarCreateError.swift' \
	! -name 'ZlibArchive.swift' ! -name 'ZlibError.swift' ! -name 'ZlibHeader.swift' \
	! -name 'BigEndianByteReader.swift')



EscapeSpace_SWIFT_BRIDGING_HEADER = EscapeOS/Engine/EscapeOS-Bridging-Header.h
EscapeSpace_CFLAGS = -IEscapeOS/Engine -IEscapeOS/Tunnel
EscapeSpace_OBJCFLAGS = -IEscapeOS/Engine -IEscapeOS/Tunnel -fobjc-arc

# Link the Rust idevice FFI static library and its system dependencies.
EscapeSpace_LDFLAGS = -LEscapeOS/Tunnel -lidevice_ffi -lresolv -framework Security -framework Network -framework SystemConfiguration -framework QuickLook -framework PDFKit -framework AVKit -framework AVFoundation -framework CoreLocation -framework CryptoKit
EscapeSpace_CODESIGN_FLAGS = -SEscapeSpace.entitlements

include $(THEOS_MAKE_PATH)/application.mk

