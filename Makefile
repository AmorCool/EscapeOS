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
	EscapeOS/Views/AppStoreDownloadView.swift \
	EscapeOS/Views/AddAccountSheet.swift \
	EscapeOS/Views/AppStoreSearchView.swift \
	EscapeOS/Views/KernelCacheView.swift \
	EscapeOS/Views/ProfileInstallView.swift \
	EscapeOS/Views/LiquidGlassDemoView.swift \
	EscapeOS/Views/GlassStyle.swift \
	EscapeOS/Views/LiquidGlassAppearance.swift \
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
	EscapeOS/Engine/AppStoreDownloadStore.swift \
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

# LiquidGlassKit：iOS 26 以下系统的 Liquid Glass backport（Metal 渲染，零第三方依赖）。
EscapeSpace_FILES += $(shell find vendor/LiquidGlassKit/Sources -name '*.swift')

# ApplePackage（移植自 asspp）：App Store 登录 / 搜索 / 下载 IPA / 历史版本。
# 网络层已用 URLSession 重写（原 AsyncHTTPClient 兼容 shim），ZIP 用项目已有的
# SWCompression，无需引任何 SwiftPM 依赖。
EscapeSpace_FILES += $(shell find vendor/ApplePackage -name '*.swift')

EscapeSpace_SWIFT_BRIDGING_HEADER = EscapeOS/Engine/EscapeOS-Bridging-Header.h
EscapeSpace_CFLAGS = -IEscapeOS/Engine -IEscapeOS/Tunnel
EscapeSpace_OBJCFLAGS = -IEscapeOS/Engine -IEscapeOS/Tunnel -fobjc-arc

# Link the Rust idevice FFI static library and its system dependencies.
# Metal/MetalKit/CVP：LiquidGlassKit 的玻璃效果渲染依赖（MetalPerformanceShaders
# 用于背景模糊采样）。
EscapeSpace_LDFLAGS = -LEscapeOS/Tunnel -lidevice_ffi -lresolv -framework Security -framework Network -framework SystemConfiguration -framework QuickLook -framework PDFKit -framework AVKit -framework AVFoundation -framework CoreLocation -framework CryptoKit -framework Metal -framework MetalKit -framework MetalPerformanceShaders -framework CoreVideo
EscapeSpace_CODESIGN_FLAGS = -SEscapeSpace.entitlements

include $(THEOS_MAKE_PATH)/application.mk

# ---------------------------------------------------------------------------
# LiquidGlassKit Metal shader 编译
#
# Theos 的源文件类型（C/C++/ObjC/Swift/Logos）**不含 .metal**，没有原生规则，
# 需要手动调用 Xcode 的 metal 编译器：.metal -> .air -> .metallib，再把产物
# 打进 App 主 bundle（代码侧从 Bundle.main 读 LiquidGlassKit.metallib，见
# LiquidGlassView.swift 的 LiquidGlassRenderer）。
#
# 失败不阻塞构建：metallib 缺失时 LiquidGlassRenderer.isAvailable == false，
# 视图安全降级（不绘制玻璃效果），App 不会崩溃。
# ---------------------------------------------------------------------------
LIQUIDGLASS_SRCDIR = vendor/LiquidGlassKit/Sources/LiquidGlassKit
LIQUIDGLASS_METAL := $(wildcard $(LIQUIDGLASS_SRCDIR)/*.metal)
LIQUIDGLASS_AIRDIR = $(THEOS_OBJ_DIR)/liquidglass
LIQUIDGLASS_METALLIB = $(THEOS_OBJ_DIR)/LiquidGlassKit.metallib

$(LIQUIDGLASS_METALLIB): $(LIQUIDGLASS_METAL)
	@echo "[LiquidGlass] Compiling Metal shaders: $(notdir $(LIQUIDGLASS_METAL))"
	@mkdir -p $(LIQUIDGLASS_AIRDIR)
	@ok=1; \
	for f in $(LIQUIDGLASS_METAL); do \
		if xcrun -sdk iphoneos metal -c "$$f" -mios-version-min=18.0 \
			-o "$(LIQUIDGLASS_AIRDIR)/$$(basename $$f .metal).air" 2>&1; then :; else ok=0; fi; \
	done; \
	if [ "$$ok" = "1" ] && xcrun -sdk iphoneos metallib $(LIQUIDGLASS_AIRDIR)/*.air -o "$@" 2>&1; then \
		echo "[LiquidGlass] metallib built: $@"; \
	else \
		echo "[LiquidGlass] WARNING: Metal shader build failed — Liquid Glass falls back (no effect)"; \
		rm -f "$@"; \
	fi

before-package:: $(LIQUIDGLASS_METALLIB)
	@if [ -f "$(LIQUIDGLASS_METALLIB)" ]; then \
		mkdir -p "$(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app"; \
		cp "$(LIQUIDGLASS_METALLIB)" "$(THEOS_STAGING_DIR)/Applications/$(APPLICATION_NAME).app/LiquidGlassKit.metallib"; \
		echo "[LiquidGlass] metallib staged into app bundle"; \
	else \
		echo "[LiquidGlass] WARNING: no metallib to stage — Liquid Glass disabled"; \
	fi
