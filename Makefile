TARGET = iphone:clang:16.5:18.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = EscapeSpace

# Public release with iOS 26 Liquid Glass tab bar requires Xcode 26 on macOS — see docs/BUILD.md.
# WSL/Theos uses iPhoneOS16.5.sdk because Apple SDK 18+/26+ needs Apple Clang, not Linux clang.

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = EscapeSpace

EscapeSpace_FILES = \
	EscapeOS/EscapeOSApp.swift \
	EscapeOS/Views/RootView.swift \
	EscapeOS/Views/AppListView.swift \
	EscapeOS/Views/AppDetailView.swift \
	EscapeOS/Views/FileBrowserView.swift \
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
	EscapeOS/Views/IncreaseMemoryView.swift \
	EscapeOS/Views/AppleIDLoginSheet.swift \
	EscapeOS/Views/PairingFilePicker.swift \
	EscapeOS/Views/SharedDocumentPicker.swift \
	EscapeOS/Views/DDIDownloadView.swift \
	EscapeOS/Views/DomainBlockerView.swift \
	EscapeOS/Views/DesignSystem.swift \
	EscapeOS/Views/Wallpaper/WallpaperModels.swift \
	EscapeOS/Views/Wallpaper/WallpaperHandler.swift \
	EscapeOS/Views/Wallpaper/WallpaperView.swift \
	EscapeOS/Engine/ZipReader.swift \
	EscapeOS/Engine/BackupPaths.swift \
	EscapeOS/Engine/RestoreService.swift \
	EscapeOS/Engine/SandboxEscape.swift \
	EscapeOS/Engine/FileKind.swift \
	EscapeOS/Engine/FileClipboard.swift \
	EscapeOS/Engine/FileService.swift \
	EscapeOS/Engine/ProfileHTTPServer.swift \
	EscapeOS/Engine/AppDiscovery.swift \
	EscapeOS/Engine/BackupService.swift \
	EscapeOS/Engine/ZipWriter.swift \
	EscapeOS/Engine/ZipPassword.swift \
	EscapeOS/Engine/SevenZipAES.swift \
	EscapeOS/Engine/ArchiveExtractor.swift \
	EscapeOS/Engine/ReclaimService.swift \
	EscapeOS/Engine/LiveContainerDiscovery.swift \
	EscapeOS/Engine/UninstallService.swift \
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
	EscapeOS/Services/MemoryLimitSettings.swift

EscapeSpace_FILES += $(shell find vendor/BitByteData/Sources vendor/SWCompression/Sources -name '*.swift' \
	! -name 'TarWriter.swift' ! -name 'TarReader.swift' ! -name 'TarCreateError.swift' \
	! -name 'ZlibArchive.swift' ! -name 'ZlibError.swift' ! -name 'ZlibHeader.swift' \
	! -name 'BigEndianByteReader.swift')

EscapeSpace_SWIFT_BRIDGING_HEADER = EscapeOS/Engine/EscapeOS-Bridging-Header.h
EscapeSpace_CFLAGS = -IEscapeOS/Engine -IEscapeOS/Tunnel
EscapeSpace_OBJCFLAGS = -IEscapeOS/Engine -IEscapeOS/Tunnel -fobjc-arc

# Link the Rust idevice FFI static library and its system dependencies.
EscapeSpace_LDFLAGS = -LEscapeOS/Tunnel -lidevice_ffi -lresolv -framework Security -framework Network -framework SystemConfiguration -framework QuickLook -framework PDFKit -framework AVKit -framework AVFoundation -framework CoreLocation
EscapeSpace_CODESIGN_FLAGS = -SEscapeSpace.entitlements

include $(THEOS_MAKE_PATH)/application.mk
