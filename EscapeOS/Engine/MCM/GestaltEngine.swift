//
//  BQMobileGestalt.swift
//  bad_query
//
//  MobileGestalt.plist tweaking engine built on the bad_query sandbox escape.
//  Ported from mond's ContentView logic, using bad_query for sandbox access.
//

import Foundation
import Observation
import SwiftUI
import UIKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Bridge to bad_query.c: consume a sandbox extension token issued by the
// LiveContainer host (livecontainer branch) for the MobileGestalt cache.
@_silgen_name("mg_consume_token") func mg_consume_token(_ token: UnsafePointer<CChar>) -> Int64

// MARK: - BQError (ported from Jade / Wind0ws11Aero)

enum BQError: LocalizedError {
    case extensionFailed(Int64)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .extensionFailed(let code):
            switch code {
            case -255: return "Path is not absolute"
            case -254: return "Path does not exist"
            case -1: return "Failed to resolve containermanager functions"
            case -2: return "Failed to create container query"
            case -3: return "containermanagerd refused the query (unsupported path?)"
            case -4: return "Kernel refused the sandbox extension"
            case -5: return "Internal error building the query"
            default: return "Unknown bad_query error (\(code))"
            }
        case .io(let message):
            return message
        }
    }
}

// MARK: - Alert Info

struct MGAlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    var actionLabel: String?
    var action: (() -> Void)?
}

// MARK: - Toggle Info Type

enum MGToggleInfoType {
    case info
    case warning
}

// MARK: - Model

@MainActor
@Observable
final class BQMobileGestaltModel {
    // Gestalt state
    var mgDict: NSMutableDictionary = [:]
    var gestaltPath: String = ""
    var hasExtension: Bool = false
    var isValid: Bool = false
    var isEmpty: Bool = false
    var ogSubtype: Int = 0
    var ogDeviceName: String = ""
    var subtype: Int = 0
    var enableDeviceName: Bool = false
    var lastReadFormat: PropertyListSerialization.PropertyListFormat = .binary
    var productType: String = ""
    var loaded: Bool = false

    // UI state
    var statusMessage: String = "Tap Load to begin"
    var lastError: String?
    var log: [String] = []
    var alertInfo: MGAlertInfo?
    var extensionHandle: Int64 = 0
    var isApplying = false
    var isDirty = false

    // Routing state
    /// True when the current sandbox extension came from the MHA identity route
    /// (BQMCMActivate class 13) rather than the bad_query path-traversal route.
    var mhaRouteActive = false

    // Paths
    static let systemGroupRoot = "/var/containers/Shared/SystemGroup"
    static let gestaltContainerName = "systemgroup.com.apple.mobilegestaltcache"
    static let gestaltRelativePath = "Library/Caches/com.apple.MobileGestalt.plist"

    var backupURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("GestaltBackups")
        return dir.appendingPathComponent("SavedGestalt.plist")
    }

    /// Copy the currently loaded MobileGestalt plist to a timestamped file
    /// in the temporary directory so it can be shared cleanly.
    func exportShareableBackup() -> URL? {
        guard loaded, !gestaltPath.isEmpty,
              FileManager.default.isReadableFile(atPath: gestaltPath) else {
            appendLog("backup share failed: not loaded or not readable")
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let tempDir = FileManager.default.temporaryDirectory
        let outURL = tempDir.appendingPathComponent("MobileGestalt-\(stamp).plist")

        do {
            if FileManager.default.fileExists(atPath: outURL.path) {
                try FileManager.default.removeItem(at: outURL)
            }
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: gestaltPath),
                to: outURL
            )
            appendLog("backup exported for share: \(outURL.path)")
            return outURL
        } catch {
            appendLog("backup export error: \(error)")
            return nil
        }
    }

    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func appendLog(_ message: String) {
        log.append("[\(Self.logFormatter.string(from: Date()))] \(message)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: - Path Discovery

    /// Scan SystemGroup containers to find the MobileGestalt cache plist.
    func discoverGestaltPath() -> String? {
        appendLog("discoverGestaltPath: MHA=\(MCMIntegration.isMobileHouseArrest) · target=\(Self.gestaltContainerName) · bridge=\(MCMIntegration.bridgeAvailable) · signed=\(MCMIntegration.signedCodeIdentifier)")
        // Route 1 (MHA): when the process presents the MobileHouseArrest signed
        // code identifier, use the real container API for class 13 instead of the
        // bad_query path-traversal PoC. This is the only iOS 26 path that does
        // not require a separately registered App Group.
        if MCMIntegration.isMobileHouseArrest {
            do {
                let root = try MCMIntegration.activate(
                    Self.gestaltContainerName,
                    class: .systemGroup
                )
                let candidate = "\(root)/\(Self.gestaltRelativePath)"
                if FileManager.default.fileExists(atPath: candidate) {
                    appendLog("MHA class-13 root: \(root)")
                    appendLog("MHA gestalt path: \(candidate)")
                    mhaRouteActive = true
                    hasExtension = true
                    extensionHandle = 1  // positive sentinel; real handle lives in gLeases
                    return candidate
                } else {
                    appendLog("MHA class-13 root OK but plist missing at \(candidate)")
                }
            } catch {
                appendLog("MHA class-13 activate failed: \(error)")
            }
        } else {
            appendLog("MHA identity not detected; skipping class-13 activation")
        }

        // Route 2 (bad_query direct): iOS 27 can reach SystemGroup directly.
        // These fileExists checks are useless without a sandbox extension, but
        // they are harmless and match the upstream Jade flow.
        let candidates = [
            "\(Self.systemGroupRoot)/\(Self.gestaltContainerName)/\(Self.gestaltRelativePath)",
            "/var/mobile/Library/Caches/com.apple.MobileGestalt.plist",
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            appendLog("gestalt found at hardcoded path")
            return candidate
        }

        // Route 3 (bad_query scan): get a sandbox extension for the SystemGroup
        // root and enumerate to find the mobilegestaltcache container.
        guard grantExtension(for: Self.systemGroupRoot) else {
            appendLog("cannot scan SystemGroup root - no extension")
            return nil
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: Self.systemGroupRoot) else {
            appendLog("cannot list SystemGroup root")
            return nil
        }

        for entry in entries where entry.contains("mobilegestaltcache") {
            let candidate = "\(Self.systemGroupRoot)/\(entry)/\(Self.gestaltRelativePath)"
            if FileManager.default.fileExists(atPath: candidate) {
                appendLog("gestalt found via scan: \(entry)")
                return candidate
            }
        }

        appendLog("gestalt container not found in SystemGroup")
        return nil
    }

    // MARK: - Sandbox Extension

    @discardableResult
    func grantExtension(for path: String) -> Bool {
        if path == gestaltPath && extensionHandle > 0 {
            hasExtension = true
            return true
        }

        var cPath = path.utf8CString.map { Int8($0) }
        var handle = bad_query(&cPath, true, nil, false)
        var route = "system"

        if handle < 0 {
            // Fallback 1: App Group sacrifice route (iOS 26). Only meaningful if
            // a real host App Group was detected — a placeholder can never work.
            let ag = BQMCMAppGroupIdentifier()
            let isPlaceholder = ag.isEmpty || ag.hasSuffix(".placeholder")
            if !isPlaceholder {
                var cGroup = ag.utf8CString.map { Int8($0) }
                var fallback = bad_query(&cPath, true, &cGroup, true)
                if fallback < 0 {
                    fallback = bad_query(&cPath, true, &cGroup, false)
                }
                if fallback > 0 {
                    handle = fallback
                    route = "app group"
                }
            }
            // Fallback 2: InternalDaemon escape base (approach D, experimental).
            // Uses a system daemon's class-10 container (e.g. com.apple.lsd) as
            // the traversal base on iOS 26 when neither systemgroup nor App
            // Group routes succeed. Harmless if it also fails.
            if handle < 0 {
                let d = bad_query_internal_daemon(&cPath, true)
                if d > 0 {
                    handle = d
                    route = "internal daemon"
                }
            }
        }

        if handle > 0 {
            extensionHandle = handle
            hasExtension = true
            appendLog("extension \(handle) acquired (\(route) route) for \(path)")
            statusMessage = "Sandbox extension active"
            return true
        } else {
            hasExtension = false
            lastError = "bad_query returned \(handle) for \(path)"
            appendLog("extension failed (\(handle)) for \(path)")
            return false
        }
    }

    // MARK: - Load

    func load() {
        appendLog("load() start: iOS \(UIDevice.current.systemVersion) · device \(machineName()) · isDeviceGood=\(isDeviceGood()) · MHA=\(MCMIntegration.isMobileHouseArrest) · signed=\(MCMIntegration.signedCodeIdentifier) · bundle=\(Bundle.main.bundleIdentifier ?? "?")")
        // Discover path
        guard let path = discoverGestaltPath() else {
            alertInfo = MGAlertInfo(title: "Not Found", body: "MobileGestalt.plist was not found. This tool requires iOS 27 for SystemGroup access, or iOS 26 with App Group sacrifice.")
            statusMessage = "Gestalt plist not found"
            return
        }
        gestaltPath = path

        // Primary write path (iOS 26 / LiveContainer): issue the sandbox extension
        // and consume it IN THIS process. The host-issued-token handoff has proven
        // unreliable (the token never reaches the guest), so we do it where it can be
        // diagnosed from this process's own (capturable) log.
        issueAndConsumeSelfInProcess()
        // Fallback: consume a token the LiveContainer host may have issued and passed
        // via ESC_MG_TOKEN (kept for compatibility; has never succeeded so far).
        if !hasExtension {
            consumeLiveContainerToken()
        }

        // Get sandbox extension for the container (unless MHA already gave us one).
        // NOTE: grantExtension (bad_query) is best-effort ONLY. When LiveContainer grants a
        // real sandbox extension to this guest process (livecontainer branch patch), the direct
        // file read/write below succeeds even if bad_query returns -4. So we must NOT gate
        // load() on grantExtension failing.
        if !mhaRouteActive {
            let containerPath = String(path.prefix(path.range(of: "/Library/")?.lowerBound.utf16Offset(in: path) ?? path.count))
            if grantExtension(for: containerPath) {
                appendLog("bad_query sandbox extension acquired (handle \(extensionHandle))")
            } else {
                appendLog("bad_query extension unavailable (handle \(extensionHandle)); relying on externally-granted (LiveContainer) sandbox extension for direct file access")
            }
        } else {
            appendLog("using MHA-activated class-13 lease; skipping bad_query grantExtension")
        }

        // Probe whether the gestalt path is directly readable by this process. If LiveContainer
        // granted a sandbox extension for it, this is true and the load below succeeds.
        let directReadable = FileManager.default.isReadableFile(atPath: path)
        appendLog("direct-access probe: readable=\(directReadable) for \(path)")

        do {
            let url = URL(fileURLWithPath: path)

            // Validate
            let rawData = try Data(contentsOf: url)
            var format = PropertyListSerialization.PropertyListFormat.binary
            isValid = (try? PropertyListSerialization.propertyList(from: rawData, options: [], format: &format)) != nil
            isEmpty = rawData.isEmpty || (rawData.count < 10)
            lastReadFormat = format

            // Load plist
            mgDict = try NSMutableDictionary(contentsOf: url, error: ())
            loaded = true

            // Create backup
            let backupDir = backupURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.copyItem(at: url, to: backupURL)
                appendLog("backup created at \(backupURL.path)")
            }

            // Get original values from backup
            let savedDict = try NSMutableDictionary(contentsOf: backupURL, error: ())
            let ogCacheExtra = savedDict["CacheExtra"] as? NSMutableDictionary ?? [:]
            let ogArtwork = ogCacheExtra["oPeik/9e8lQWMszEjbPzng"] as? NSMutableDictionary ?? [:]

            guard let ogSub = ogArtwork["ArtworkDeviceSubType"] as? Int else {
                lastError = "Failed to get ArtworkDeviceSubType from backup"
                appendLog("error: no ArtworkDeviceSubType in backup")
                return
            }
            ogSubtype = ogSub
            subtype = ogSub

            guard let ogName = ogArtwork["ArtworkDeviceProductDescription"] as? String else {
                lastError = "Failed to get ArtworkDeviceProductDescription from backup"
                appendLog("error: no ArtworkDeviceProductDescription in backup")
                return
            }
            ogDeviceName = ogName

            // Get current values
            let cacheExtra = mgDict["CacheExtra"] as? NSMutableDictionary ?? [:]
            let artwork = cacheExtra["oPeik/9e8lQWMszEjbPzng"] as? NSMutableDictionary ?? [:]
            subtype = artwork["ArtworkDeviceSubType"] as? Int ?? ogSub
            let currentName = artwork["ArtworkDeviceProductDescription"] as? String ?? ogName
            enableDeviceName = (currentName != ogName)

            if let pt = cacheExtra["h9jDsbgj7xIVeIQ8S3/X3Q"] as? String, !pt.isEmpty {
                productType = pt
            } else {
                productType = machineName()
            }

            statusMessage = "MobileGestalt loaded"
            appendLog("gestalt loaded — subtype=\(ogSub), device=\(ogName)")
            isDirty = false
        } catch {
            lastError = "Failed to load: \(error.localizedDescription)"
            alertInfo = MGAlertInfo(title: "Failed to load MobileGestalt!", body: "Restart the app and try again. Check logs for details.")
            appendLog("load error: \(error)")
        }
    }

    /// Consume the LiveContainer-issued MobileGestalt sandbox extension token in
    /// THIS process. The LiveProcess guest passes the raw token through the
    /// ESC_MG_TOKEN environment variable; consuming it here (not relying on the
    /// LiveProcess parent's consumed extension) is what makes in-place writes
    /// succeed inside LiveContainer on iOS 26.
    private func consumeLiveContainerToken() {
        let env = ProcessInfo.processInfo.environment
        let keys = env.keys.sorted().joined(separator: ", ")
        appendLog("ProcessInfo.environment keys: \(keys)")
        guard let token = env["ESC_MG_TOKEN"],
              !token.isEmpty else {
            appendLog("no LiveContainer-issued MobileGestalt token in ESC_MG_TOKEN environment")
            return
        }
        let handle = token.withCString { mg_consume_token($0) }
        if handle >= 0 {
            extensionHandle = handle
            hasExtension = true
            appendLog("consumed LiveContainer MobileGestalt sandbox extension in-process, handle=\(handle)")
        } else {
            appendLog("LiveContainer MobileGestalt token consume failed (handle \(handle))")
        }
    }

    /// Issue a raw sandbox extension for the MobileGestalt cache IN THIS process
    /// and immediately consume it, so in-place writes succeed inside LiveContainer
    /// on iOS 26. This is the supported sandbox pattern (issue+consume in the same
    /// process) and replaces the unreliable host-issued-token handoff. Logs the exact
    /// result so the failure mode is capturable from this app's own (exportable) log.
    /// Returns immediately (no throw) — failure just means writes will be denied.
    private func issueAndConsumeSelfInProcess() {
        let path = gestaltPath
        if path.isEmpty {
            appendLog("issueAndConsumeSelfInProcess: no gestaltPath yet")
            return
        }
        // Try the exact plist file first, then the container directory.
        let fileHandle = path.withCString { mg_issue_and_consume($0) }
        appendLog("in-process sandbox issue+consume (file): handle=\(fileHandle) for \(path)")
        if fileHandle >= 0 {
            extensionHandle = fileHandle
            hasExtension = true
            appendLog("in-process MobileGestalt sandbox extension ACTIVE (handle \(fileHandle))")
            return
        }
        let containerPath = String(path.prefix(path.range(of: "/Library/")?.lowerBound.utf16Offset(in: path) ?? path.count))
        let dirHandle = containerPath.withCString { mg_issue_and_consume($0) }
        appendLog("in-process sandbox issue+consume (container): handle=\(dirHandle) for \(containerPath)")
        if dirHandle >= 0 {
            extensionHandle = dirHandle
            hasExtension = true
            appendLog("in-process MobileGestalt sandbox extension ACTIVE (handle \(dirHandle))")
        }
    }

    // MARK: - Apply

    func apply() {
        isApplying = true
        do {
            let cacheExtra = mgDict["CacheExtra"] as? NSMutableDictionary ?? NSMutableDictionary()
            mgDict["CacheExtra"] = cacheExtra

            if !productType.isEmpty {
                cacheExtra["h9jDsbgj7xIVeIQ8S3/X3Q"] = productType
            }

            let artwork = cacheExtra["oPeik/9e8lQWMszEjbPzng"] as? NSMutableDictionary ?? NSMutableDictionary()
            cacheExtra["oPeik/9e8lQWMszEjbPzng"] = artwork
            artwork["ArtworkDeviceSubType"] = subtype
            if enableDeviceName {
                artwork["ArtworkDeviceProductDescription"] = customDeviceName
            }

            let data = try PropertyListSerialization.data(fromPropertyList: mgDict, format: lastReadFormat, options: 0)
            try write(data)

            statusMessage = "Tweaks applied — reboot to take effect"
            appendLog("applied gestalt tweaks (\(data.count) bytes)")
            isDirty = false
            alertInfo = MGAlertInfo(
                title: "Successfully applied Gestalt tweaks!",
                body: "Reboot your device for changes to take effect.",
                actionLabel: "Reboot",
                action: { self.respring() }
            )
        } catch {
            appendLog("apply error: \(error)")
            alertInfo = MGAlertInfo(title: "Failed to apply MobileGestalt!", body: "Check logs for error information.")
        }
        isApplying = false
    }

    // MARK: - Revert

    func revert() {
        do {
            let backupData = try Data(contentsOf: backupURL)
            try write(backupData)
            statusMessage = "Reverted — reboot to take effect"
            appendLog("reverted gestalt from backup")
            alertInfo = MGAlertInfo(title: "Successfully reverted Gestalt tweaks!", body: "Reboot your device for changes to take effect.")
            // Reload current values
            load()
        } catch {
            appendLog("revert error: \(error)")
            alertInfo = MGAlertInfo(title: "Failed to revert MobileGestalt!", body: "Check logs for error information.")
        }
    }

    // MARK: - Write (in-place fd overwrite, same inode)

    private func write(_ data: Data) throws {
        let targetPath = gestaltPath

        // Read original for rollback
        let original = FileManager.default.contents(atPath: targetPath)

        // Open the original file in-place (O_NOFOLLOW prevents symlink hijacking)
        let fd = targetPath.withCString { path in
            open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw BQError.io("Failed to open plist for in-place write (errno=\(errno))")
        }
        defer { close(fd) }

        // Truncate, write, fsync — all on the same inode
        let success = ftruncate(fd, 0) == 0 &&
            lseek(fd, 0, SEEK_SET) == 0 &&
            writeAll(fd: fd, data: data) &&
            fsync(fd) == 0

        if !success {
            // Rollback to original on failure
            if let original {
                ftruncate(fd, 0)
                lseek(fd, 0, SEEK_SET)
                _ = writeAll(fd: fd, data: original)
                fsync(fd)
            }
            throw BQError.io("Failed to write plist in-place (errno=\(errno))")
        }

        // Verify
        if let verification = FileManager.default.contents(atPath: targetPath),
           verification != data {
            throw BQError.io("Post-write verification failed")
        }

        appendLog("wrote \(data.count) bytes in-place to \(targetPath)")
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            var ptr = buffer.baseAddress!
            var remaining = buffer.count
            while remaining > 0 {
                let written = Foundation.write(fd, ptr, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                ptr = ptr.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    // MARK: - Device Name Persistence

    /// Stored in UserDefaults so the custom name persists across launches.
    var customDeviceName: String {
        get { UserDefaults.standard.string(forKey: "mg_devicename") ?? ogDeviceName }
        set { UserDefaults.standard.set(newValue, forKey: "mg_devicename") }
    }

    // MARK: - cache_data_offset

    func cacheDataOffset(_ key: String) -> Int {
        guard let cacheKeys = mgDict["CacheKeys"] as? [String] else { return -1 }
        guard let index = cacheKeys.firstIndex(of: key) else { return -1 }
        return index * MemoryLayout<Int>.size
    }

    // MARK: - Bindings

    func keyBinding<T: Equatable>(
        _ keys: [String],
        type: T.Type = Int.self,
        defaultVal: T? = 0,
        onVal: T? = 1
    ) -> Binding<Bool> {
        Binding(get: { [weak self] in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return false }
            if let value = cacheExtra[keys.first!] as? T, let onVal {
                return value == onVal
            }
            return false
        }, set: { [weak self] enabled in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return }
            for key in keys {
                if enabled {
                    cacheExtra[key] = onVal
                } else {
                    cacheExtra.removeObject(forKey: key)
                }
            }
        })
    }

    func trollpadBinding() -> Binding<Bool> {
        Binding(get: { [weak self] in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return false }
            return (cacheExtra["uKc7FPnEO++lVhHWHFlGbQ"] as? Int) == 1
        }, set: { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.alertInfo = MGAlertInfo(
                    title: "Warning!",
                    body: "This is a very dangerous tweak! If you use an alphanumeric passcode, DO NOT USE THIS! Do not turn off \"Show Dock In Stage Manager\" or your device will BOOTLOOP in landscape! You may experience general instability or data loss."
                )
            }
            guard let cacheData = self.mgDict["CacheData"] as? NSMutableData,
                  let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return }
            let valueOff = self.cacheDataOffset("mtrAoWJ3gsq+I90ZnQ0vQw")
            let keys = [
                "uKc7FPnEO++lVhHWHFlGbQ",
                "mG0AnH/Vy1veoqoLRAIgTA",
                "UCG5MkVahJxG1YULbbd5Bg",
                "ZYqko/XM5zD3XBfN5RmaXA",
                "nVh/gwNpy7Jv1NOk00CMrw",
                "qeaj75wk3HF4DwQ8qbIi7g",
            ]
            cacheData.mutableBytes.storeBytes(of: enabled ? 3 : 1, toByteOffset: valueOff, as: Int.self)
            for key in keys {
                if enabled {
                    cacheExtra[key] = 1
                } else {
                    cacheExtra.removeObject(forKey: key)
                }
            }
        })
    }

    func regionRestrictBinding() -> Binding<Bool> {
        Binding(get: { [weak self] in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return false }
            return (cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] as? String) == "US" &&
                   (cacheExtra["zHeENZu+wbg7PUprwNwBWg"] as? String) == "LL/A"
        }, set: { [weak self] enabled in
            guard let self, let cacheExtra = self.mgDict["CacheExtra"] as? NSMutableDictionary else { return }
            if enabled {
                self.alertInfo = MGAlertInfo(
                    title: "Warning!",
                    body: "Do not use this to bypass region restrictions that would violate local laws. We are not responsible for any illegal activities."
                )
                cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] = "US"
                cacheExtra["zHeENZu+wbg7PUprwNwBWg"] = "LL/A"
            } else {
                cacheExtra.removeObject(forKey: "h63QSdBCiT/z0WU6rdQv6Q")
                cacheExtra.removeObject(forKey: "zHeENZu+wbg7PUprwNwBWg")
            }
        })
    }

    func internalBinding() -> Binding<Bool> {
        Binding(get: { [weak self] in
            guard let self, let cacheData = self.mgDict["CacheData"] as? NSMutableData else { return false }
            let off = self.cacheDataOffset("EqrsVvjcYDdxHBiQmGhAWw")
            guard off >= 0, off < cacheData.length else { return false }
            return cacheData.bytes.load(fromByteOffset: off, as: Int.self) == 1
        }, set: { [weak self] enabled in
            guard let self, let cacheData = self.mgDict["CacheData"] as? NSMutableData else { return }
            let offsets = [
                self.cacheDataOffset("EqrsVvjcYDdxHBiQmGhAWw"),
                self.cacheDataOffset("Oji6HRoPi7rH7HPdWVakuw"),
                self.cacheDataOffset("LBJfwOEzExRxzlAnSuI7eg"),
            ]
            for off in offsets where off >= 0 && off < cacheData.length {
                cacheData.mutableBytes.storeBytes(of: enabled ? 1 : 0, toByteOffset: off, as: Int.self)
            }
        })
    }

    // MARK: - Device Helpers

    func machineName() -> String {
        var sysInfo = utsname()
        uname(&sysInfo)
        let mirror = Mirror(reflecting: sysInfo.machine)
        return mirror.children.reduce("") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return result }
            return result + String(UnicodeScalar(UInt8(value)))
        }
    }

    func doubleSystemVersion() -> Double {
        Double(UIDevice.current.systemVersion) ?? 0
    }

    func hasHomeButton() -> Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let bottom = scene?.windows.first?.safeAreaInsets.bottom ?? 0
        return bottom == 0
    }

    func isDeviceGood() -> Bool {
        let supported: [String] = [
            "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5",
            "iPhone16,1", "iPhone16,2",
            "iPhone17,3", "iPhone17,4", "iPhone17,1", "iPhone17,2",
            "iPhone18,3", "iPhone18,1", "iPhone18,2", "iPhone17,5",
        ]
        return supported.contains(machineName()) && doubleSystemVersion() < 19.0
    }

    // MARK: - Respring

    func respring() {
        guard let url = URL(string: "shortcuts://run-shortcut?name=reboot"), UIApplication.shared.canOpenURL(url) else {
                print("Can't Open URL: \("shortcuts://run-shortcut?name=reboot")")
                return
            }
            UIApplication.shared.open(url, options: [:]) { success in
                if !success { print("No shortcut") }
            }
    }
}
