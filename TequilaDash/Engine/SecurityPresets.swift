import Foundation

/// v0.3.203: Security detection presets auto-generated from aisi SecurityPresets.plist (do not edit).
/// Detection methodology mirrors Lessica/Reveil (embedded IOSSecuritySuite).
enum SecurityPresets {

    /// secureStandaloneLibraries (8 items)
    static let secureStandaloneLibraries: [String] = [
        "/private/preboot/Cryptexes/OS/usr/lib/libobjc-trampolines.dylib",
        "/private/preboot/Cryptexes/OS/usr/lib/libglInterpose.dylib",
        "/usr/lib/libobjc-trampolines.dylib",
        "/usr/lib/libBacktraceRecording.dylib",
        "/usr/lib/libRPAC.dylib",
        "/usr/lib/system/introspection/libdispatch.dylib",
        "/usr/lib/libMainThreadChecker.dylib",
        "/usr/lib/libViewDebuggerSupport.dylib",
    ]

    /// secureEntitlementKeys (13 items)
    static let secureEntitlementKeys: [String] = [
        "com.apple.private.security.no-sandbox",
        "get-task-allow",
        "application-identifier",
        "platform-application",
        "keychain-access-groups",
        "com.apple.security.network.client",
        "beta-reports-active",
        "com.apple.security.iokit-user-client-class",
        "com.apple.security.app-sandbox",
        "com.apple.private.security.storage.AppDataContainers",
        "com.apple.private.security.container-required",
        "com.apple.developer.team-identifier",
        "aps-environment",
    ]

    /// suspiciousAccessibleInterpreters (3 items)
    static let suspiciousAccessibleInterpreters: [String] = [
        "/usr/sbin/sshd",
        "/bin/bash",
        "/usr/bin/ssh",
    ]

    /// suspiciousAccessibleDirectories (5 items)
    static let suspiciousAccessibleDirectories: [String] = [
        "/",
        "/root/",
        "/jb/",
        "/Library/",
        "/private/",
    ]

    /// suspiciousFiles (126 items)
    static let suspiciousFiles: [String] = [
        "/var/root/Library/Preferences/ws.hbang.Terminal.plist",
        "/Library/MobileSubstrate/DynamicLibraries/PreferenceLoader.dylib",
        "/var/root/Library/Preferences/com.xina.blacklist.plist",
        "/var/mobile/Library/Preferences/com.xina.jailbreak.plist",
        "/Library/PreferenceBundles/libhbangprefs.bundle",
        "/Applications/IntelliScreen.app",
        "/usr/libexec/cydia/firmware.sh",
        "/var/log/apt",
        "/.cydia_no_stash",
        "/var/lib/dpkg/info/mobilesubstrate.md5sums",
        "/private/var/zshrc",
        "/Applications/Zebra.app",
        "/etc/apt/sources.list.d/sileo.sources",
        "/etc/apt",
        "/Applications/blackra1n.app",
        "/var/mobile/Library/Application Support/xyz.willy.Zebra",
        "/private/var/apt",
        "/Applications/iFile.app",
        "/private/var/tmp/cydia.log",
        "/private/var/zlogin",
        "/var/mobile/Library/Sileo",
        "/var/mobile/Library/Saved Application State/ws.hbang.Terminal.savedState",
        "/Library/PreferenceBundles/LibertyPref.bundle",
        "/Library/MobileSubstrate/DynamicLibraries/Veency.plist",
        "/etc/apt/sources.list.d/electra.list",
        "/var/mobile/Library/Caches/org.coolstar.SileoStore",
        "/var/mobile/Library/Saved Application State/xyz.willy.Zebra.savedState",
        "/Applications/SBSettings.app",
        "/usr/lib/libsubstitute.dylib",
        "/usr/share/jailbreak/injectme.plist",
        "/var/mobile/Library/SplashBoard/Snapshots/xyz.willy.Zebra",
        "/etc/apt/undecimus/undecimus.list",
        "/var/mobile/Library/Caches/com.tigisoftware.Filza",
        "/var/mobile/Library/SplashBoard/Snapshots/com.xina.jailbreak",
        "/var/mobile/Library/SplashBoard/Snapshots/ru.domo.cocoatop64",
        "/Applications/WinterBoard.app",
        "/Library/MobileSubstrate/DynamicLibraries/LiveClock.plist",
        "/var/mobile/Library/HTTPStorages/xyz.willy.Zebra",
        "/Library/MobileSubstrate/DynamicLibraries",
        "/System/Library/LaunchDaemons/com.ikey.bbot.plist",
        "/var/mobile/Library/Caches/Cephei",
        "/jb/amfid_payload.dylib",
        "/private/var/zshenv",
        "/private/var/lib/cydia",
        "/var/mobile/Library/SplashBoard/Snapshots/com.tigisoftware.Filza",
        "/Library/PreferenceBundles/SubstitutePrefs.bundle",
        "/var/mobile/Library/Caches/xyz.willy.Zebra",
        "/Applications/Icy.app",
        "/Library/PreferenceBundles/ShadowPreferences.bundle",
        "/var/mobile/Library/Preferences/ABPattern",
        "/.bootstrapped_electra",
        "/var/root/.bash_history",
        "/var/mobile/.ekenablelogging",
        "/var/mobile/Library/Application Support/Containers/xyz.willy.Zebra",
        "/private/var/master.passwd",
        "/var/mobile/.eksafemode",
        "/private/var/Users/",
        "/Applications/RockApp.app",
        "/var/mobile/Library/Saved Application State/org.coolstar.SileoStore.savedState",
        "/var/mobile/Library/Application Support/Containers/org.coolstar.SileoStore",
        "/var/root/Library/Preferences/com.xina.jailbreak.plist",
        "/var/mobile/Library/Saved Application State/com.tigisoftware.Filza.savedState",
        "/private/var/zprofile",
        "/var/root/Library/HTTPStorages/shshd",
        "/Library/PreferenceBundles/FlyJBPrefs.bundle",
        "/usr/lib/ABDYLD.dylib",
        "/var/mobile/Library/HTTPStorages/org.coolstar.SileoStore",
        "/var/binpack/Applications/loader.app",
        "/private/var/sudo_logsrvd.conf",
        "/var/mobile/Library/Preferences/me.jjolano.shadow.plist",
        "/var/mobile/Library/HTTPStorages/com.tigisoftware.Filza",
        "/Applications/FlyJB.app",
        "/var/mobile/Library/Preferences/org.coolstar.SileoStore.plist",
        "/var/binpack",
        "/Library/MobileSubstrate/DynamicLibraries/PreferenceLoader.plist",
        "/Library/MobileSubstrate/CydiaSubstrate.dylib",
        "/Applications/Cydia.app",
        "/var/mobile/Library/SplashBoard/Snapshots/ws.hbang.Terminal",
        "/var/mobile/Library/Application Support/Containers/com.tigisoftware.Filza",
        "/Library/PreferenceBundles/Cephei.bundle",
        "/usr/lib/TweakInject",
        "/var/mobile/Library/Flex3",
        "/usr/lib/libhooker.dylib",
        "/Library/MobileSubstrate/DynamicLibraries/SSLKillSwitch2.plist",
        "/usr/lib/ABSubLoader.dylib",
        "/var/mobile/Library/Saved Application State/ru.domo.cocoatop64.savedState",
        "/var/mobile/Library/Preferences/ru.domo.cocoatop64.plist",
        "/usr/sbin/frida-server",
        "/Applications/Filza.app",
        "/private/var/ssh",
        "/.installed_unc0ver",
        "/Applications/MxTube.app",
        "/private/var/mobile/Library/SBSettings/Themes",
        "/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist",
        "/var/mobile/Library/Filza",
        "/var/mobile/Library/WebKit/xyz.willy.Zebra",
        "/private/var/stash",
        "/var/mobile/Library/SplashBoard/Snapshots/org.coolstar.SileoStore",
        "/Library/PreferenceBundles/ABypassPrefs.bundle",
        "/jb/offsets.plist",
        "/usr/lib/substrate",
        "/Applications/FakeCarrier.app",
        "/Applications/Sileo.app",
        "/jb/lzma",
        "/jb/libjailbreak.dylib",
        "/Applications/Flex3.app",
        "/private/var/lib/apt",
        "/private/var/zlogout",
        "/private/var/cache/apt/",
        "/var/mobile/Library/Preferences/ws.hbang.Terminal.plist",
        "/Library/BawAppie/ABypass",
        "/private/var/log/syslog",
        "/var/mobile/Library/UserConfigurationProfiles/PublicInfo/Flex3Patches.plist",
        "/var/mobile/Library/Preferences/com.tigisoftware.Filza.plist",
        "/var/mobile/Library/Caches/ws.hbang.Terminal",
        "/usr/lib/libjailbreak.dylib",
        "/var/mobile/Library/Preferences/xyz.willy.Zebra.plist",
        "/private/var/suid_profile",
        "/var/root/Library/Caches/shshd",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/var/mobile/Library/Cookies/com.johncoates.Flex.binarycookies",
        "/jb/jailbreakd.plist",
        "/Applications/NewTerm.app",
        "/var/lib/cydia",
        "/private/var/lib/apt/",
        "/var/mobile/Library/HTTPStorages/ws.hbang.Terminal",
    ]

    /// suspiciousSymbolicLinks (8 items)
    static let suspiciousSymbolicLinks: [String] = [
        "/Library/Wallpaper",
        "/usr/include",
        "/usr/libexec",
        "/var/lib/undecimus/apt",
        "/usr/arm-apple-darwin9",
        "/Library/Ringtones",
        "/usr/share",
        "/Applications",
    ]

    /// suspiciousLibraryNames (5 items)
    static let suspiciousLibraryNames: [String] = [
        "cynject",
        "libcycript",
        "frida",
        "FridaGadget",
        "RevealServer",
    ]

    /// suspiciousURLSchemes (14 items)
    static let suspiciousURLSchemes: [String] = [
        "scheme=cydia://|description=Cydia",
        "scheme=undecimus://|description=Unc0ver",
        "scheme=sileo://|description=Sileo",
        "scheme=zbra://|description=Zebra",
        "scheme=apt-repo://|description=Saily",
        "scheme=postbox://|description=Postbox",
        "scheme=xina://|description=Xina",
        "scheme=icleaner://|description=iCleaner",
        "scheme=santander://|description=Santander",
        "scheme=filza://|description=Filza",
        "scheme=db-lmvo0l08204d0a0://|description=Filza (Dropbox)",
        "scheme=boxsdk-810yk37nbrpwaee5907xc4iz8c1ay3my://|description=Filza (Dropbox SDK)",
        "scheme=com.googleusercontent.apps.802910049260-0hf6uv6nsj21itl94v66tphcqnfl172r://|description=Filza (Google Drive)",
        "scheme=activator://|description=Activator",
    ]

    /// secureMobileProvisioningProfileHashes (1 items)
    static let secureMobileProvisioningProfileHashes: [String] = [
        "",
    ]

    /// insecureEnvironmentVariables (20 items)
    static let insecureEnvironmentVariables: [String] = [
        "_MSSafeMode",
        "DYLD_PRINT_BINDINGS",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_LIBRARY_PATH",
        "DYLD_PRINT_LIBRARIES",
        "DYLD_VERSIONED_LIBRARY_PATH",
        "DYLD_PRINT_LOADERS",
        "DYLD_PRINT_SEGMENTS",
        "DYLD_PRINT_ENV",
        "DYLD_PRINT_SEARCHING",
        "DYLD_PRINT_INITIALIZERS",
        "DYLD_PRINT_APIS",
        "DYLD_VERSIONED_FRAMEWORK_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_IMAGE_SUFFIX",
        "DYLD_FALLBACK_FRAMEWORK_PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_PRINT_TO_FILE",
        "DYLD_SHARED_REGION",
        "DYLD_SHARED_CACHE_DIR",
    ]

    /// suspiciousExecutables (1 items)
    static let suspiciousExecutables: [String] = [
        "/usr/sbin/frida-server",
    ]

    /// suspiciousAccessibleFiles (6 items)
    static let suspiciousAccessibleFiles: [String] = [
        "/var/log/apt",
        "/Applications/Cydia.app",
        "/.bootstrapped_electra",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/etc/apt",
        "/.installed_unc0ver",
    ]

    /// secureMainExecutableMachOHashes (1 items)
    static let secureMainExecutableMachOHashes: [String] = [
        "fdf97fd77d1b36d5aba2b44d5e9278e7942f82944ded66ce4aeeb944d8f5e0ae",
    ]

    /// suspiciousLibraries (25 items)
    static let suspiciousLibraries: [String] = [
        "frida",
        "SSLKillSwitch2.dylib",
        "RocketBootstrap",
        "Cephei",
        "MobileSubstrate.dylib",
        "libhooker",
        "SubstrateBootstrap",
        "CustomWidgetIcons",
        "Shadow",
        "SSLKillSwitch.dylib",
        "SubstrateLoader.dylib",
        "CydiaSubstrate",
        "Substitute",
        "Electra",
        "FridaGadget",
        "FlyJB",
        "WeeLoader",
        "SubstrateInserter",
        "AppSyncUnified-FrontBoard.dylib",
        "ABypass",
        "cynject",
        "libcycript",
        "TweakInject.dylib",
        "PreferenceLoader",
        "/.file",
    ]

    /// suspiciousInterpreters (7 items)
    static let suspiciousInterpreters: [String] = [
        "/usr/sbin/sshd",
        "/usr/libexec/sftp-server",
        "/bin/bash",
        "/bin/sh",
        "/etc/ssh/sshd_config",
        "/usr/libexec/ssh-keysign",
        "/usr/bin/ssh",
    ]

    /// secureMainBundleIdentifiers (1 items)
    static let secureMainBundleIdentifiers: [String] = [
        "com.82flex.reveil",
    ]

    /// suspiciousPorts (port -> name)
    static let suspiciousPorts: [(port: Int, name: String)] = [
        (46952, "X.X.T."),
        (27042, "Frida Server"),
        (4444, "Frida Gadget"),
        (22, "OpenSSH"),
        (44, "Checkra1n"),
    ]

    /// suspiciousObjCClasses (class -> selector?)
    static let suspiciousObjCClasses: [(cls: String, selector: String?)] = [
        ("ShadowRuleset", "internalDictionary"),
    ]
}