import Foundation

/// A LiveContainer instance found among the device's installed apps, together
/// with the guest apps it hosts inside its own Data container.
struct LiveContainerInstance: Identifiable {
    let id = UUID()
    let host: InstalledApp
    let guests: [LiveContainerGuest]
    let error: String?
}

/// A single app hosted inside LiveContainer, plus the metadata needed to
/// render it (real display name + icon) and to invoke the Reclaim engine
/// (a synthetic `InstalledApp` pointing at the guest's UUID container).
struct LiveContainerGuest: Identifiable {
    /// Cache key scoped to the host LC instance + UUID. Two guest UUIDs of
    /// the same app id are surfaced as separate rows.
    let id: String
    /// Guest app bundle identifier (CFBundleIdentifier of the `.app`).
    /// Falls back to the UUID when no `.app` was located.
    let bundleIdentifier: String
    /// Real display name (CFBundleDisplayName → CFBundleName → `.app` folder
    /// name → UUID). This is what the row shows.
    let displayName: String
    /// Path to the guest's UUID directory inside LiveContainer. This is what
    /// `ReclaimService` operates on as if it were a normal app container.
    let containerPath: String
    /// Raw bytes of the guest app icon (already decoded inside the sandbox
    /// extension so the UI does not need to reopen the container).
    let iconData: Data?
    /// Display name of the LiveContainer instance that hosts this guest.
    let hostName: String
    /// True when this guest's data lives in the shared AppGroup container
    /// (`<appGroup>/LiveContainer/Data/Application/<uuid>`), i.e. the app was
    /// "converted"/shared by LiveContainer. Surfaced in the UI as a "共享" pill.
    let isShared: Bool

    init(id: String,
         bundleIdentifier: String,
         displayName: String,
         containerPath: String,
         iconData: Data?,
         hostName: String,
         isShared: Bool = false) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.containerPath = containerPath
        self.iconData = iconData
        self.hostName = hostName
        self.isShared = isShared
    }

    /// Synthesized `InstalledApp` so the existing `ReclaimService.scan /
    /// .reclaim` can treat this guest exactly like a system app.
    var installedApp: InstalledApp {
        InstalledApp(
            bundleIdentifier: id,
            name: displayName,
            containerPath: containerPath,
            version: nil,
            applicationType: nil
        )
    }
}

/// Discovers apps installed *inside* LiveContainer — the "guest" apps that
/// LiveContainer sideloads into its own Data container.
///
/// Storage layout (LiveContainer source: LiveContainerSwiftUI/LCContainer.swift,
/// LiveContainerSwiftUI/LCAppInfo.m):
///   <LC Data container>/Documents/Applications/<name>.app/Info.plist
///                                         └─ LCAppInfo.plist (LCDataUUID + LCContainers)
///   <LC Data container>/Documents/Data/Application/<UUID>/      (guest sandbox)
///                                       └─ LCContainerInfo.plist
///
/// Historically the discovery logic tried to join the two halves via the
/// `appIdentifier` field in `LCContainerInfo.plist`. That fails on some LiveContainer
/// builds because they store the container UUID itself in that field. The fix is
/// to drive the join from the `.app` side instead:
///
///   1. Enumerate `Documents/Applications/*.app/`.
///   2. Read each `.app/Info.plist` for the real display name + bundle id + icon.
///   3. Read each `.app/LCAppInfo.plist` for `LCDataUUID` and the `LCContainers`
///      array (extra per-account containers).
///   4. Map those UUIDs to `Documents/Data/Application/<UUID>/`.
///
/// `LCContainerInfo.plist` is still walked as a *fallback* for any guest UUID
/// that wasn't reached through the `.app` enumeration (rare fork layouts).
final class LiveContainerDiscovery {

    private let escape = SandboxEscape()
    private let files = FileService()
    private let fm = FileManager.default

    /// Bundle-id prefixes that identify a LiveContainer instance. Covers the
    /// primary app and the alternate instances (livecontainer2, livecontainer3…).
    private let prefixes = ["com.kdt.livecontainer"]

    func discover(installedApps: [InstalledApp]) -> [LiveContainerInstance] {
        var hosts = installedApps.filter { app in
            prefixes.contains(where: { app.bundleIdentifier.lowercased().hasPrefix($0) })
        }
        // When running *inside* LiveContainer with container extensions granted
        // by the host, the tunnel-based app list may not surface the LC host.
        // Synthesize a local host from the forwarded container root so discovery
        // (and thus Reclaim/LiveClean) still works without the tunnel.
        if hosts.isEmpty,
           SandboxEscape.lcContainerExtensionsActive,
           let home = SandboxEscape.lcHomePath
               ?? (getenv("LC_HOME_PATH").map { String(cString: $0) }) {
            hosts = [InstalledApp(bundleIdentifier: "com.kdt.livecontainer.local",
                                  name: "LiveContainer (本机)",
                                  containerPath: home,
                                  version: nil, applicationType: nil)]
        }
        guard !hosts.isEmpty else { return [] }

        var instances = hosts.compactMap { host in
            let guests: [LiveContainerGuest]
            do {
                // Build the enumeration as a standalone closure so it can run
                // either under a (legacy) bad_query handle or — when the host
                // granted container extensions — directly. The consumed
                // extensions make the native FileManager calls succeed without
                // bad_query (which iOS 26 blocks with -4).
                let runEnumeration = { [self] () throws -> [LiveContainerGuest] in
                    let appsRoot = (host.containerPath as NSString).appendingPathComponent("Documents/Applications")
                    let dataRoot = (host.containerPath as NSString).appendingPathComponent("Documents/Data")

                    // Dedupe by guest UUID across both the primary (.app + LCAppInfo)
                    // and fallback (LCContainerInfo.plist) passes.
                    var guestsByUUID: [String: LiveContainerGuest] = [:]

                    func makeKey(bundleId: String, uuid: String) -> String {
                        return "\(host.bundleIdentifier)::\(bundleId)::\(uuid)"
                    }

                    // Primary pass: enumerate `.app` bundles and join them to
                    // guest containers through `.app/LCAppInfo.plist`.
                    for bundle in enumerateGuestBundles(root: appsRoot) {
                        var bundleUUIDs = bundle.dataUUIDs
                        // Some LiveContainer versions name the `.app` directory
                        // after the UUID instead of the display name. In that
                        // case `LCAppInfo.plist` is missing and `dataUUIDs` is
                        // empty — try matching the `.app` folder name as a UUID.
                        if bundleUUIDs.isEmpty, looksLikeUUID(bundle.folderName) {
                            bundleUUIDs = [bundle.folderName]
                        }
                        for uuid in bundleUUIDs {
                            let containerPath = (dataRoot as NSString)
                                .appendingPathComponent("Application/\(uuid)")
                            guard files.isDirectory(at: containerPath) else { continue }
                            guard guestsByUUID[uuid] == nil else { continue }
                            let key = makeKey(bundleId: bundle.bundleId, uuid: uuid)
                            guestsByUUID[uuid] = LiveContainerGuest(
                                id: key,
                                bundleIdentifier: bundle.bundleId,
                                displayName: bundle.displayName,
                                containerPath: containerPath,
                                iconData: bundle.iconData,
                                hostName: host.name
                            )
                        }
                    }

                    // Fallback: scan LCContainerInfo.plist files for any guest
                    // UUID the primary pass missed (older / fork layouts that
                    // don't carry LCAppInfo.plist). Private containers only.
                    var walked: [String] = []
                    for (uuidPath, dict) in collectGuestInfoPlists(in: dataRoot, depth: 0, visited: &walked) {
                        let uuid = (uuidPath as NSString).lastPathComponent
                        // Dedupe against the primary pass — same UUID = same guest.
                        guard guestsByUUID[uuid] == nil else { continue }
                        let plistName = nameFromContainerInfo(dict)
                        let appIdentifier = dict["appIdentifier"] as? String
                        let appRef = appIdentifier.flatMap { lookupAppByBundleId($0, in: appsRoot) }
                            ?? lookupAppByUUID(uuid, in: appsRoot)
                        let bundleId = appRef?.bundleId ?? appIdentifier ?? uuid
                        let displayName = appRef?.displayName ?? plistName ?? uuid
                        let key = makeKey(bundleId: bundleId, uuid: uuid)
                        guestsByUUID[uuid] = LiveContainerGuest(
                            id: key,
                            bundleIdentifier: bundleId,
                            displayName: displayName,
                            containerPath: uuidPath,
                            iconData: appRef?.iconData,
                            hostName: host.name
                        )
                    }

                    // Shared ("converted") guest containers live under the real
                    // App Group: <appGroupPath>/LiveContainer/Data/Application/<folderName>.
                    // With the host-granted extension consumed, we can now reach
                    // this previously-inaccessible sandbox (class 14) and surface
                    // those apps for scanning / reclaim.
                    if SandboxEscape.lcContainerExtensionsActive,
                       let ag = SandboxEscape.lcAppGroupPath {
                        let sharedRoot = (ag as NSString).appendingPathComponent("LiveContainer/Data/Application")
                        // Shared/converted guest `.app` bundles live in the
                        // AppGroup's *Applications* folder — not the host's
                        // Documents/Applications — so look them up there for the
                        // real display name + icon. Folder name may be the bare
                        // bundle id without a `.app` suffix (handled by
                        // enumerateGuestBundles).
                        let sharedAppsRoot = (ag as NSString).appendingPathComponent("LiveContainer/Applications")
                        for (uuidPath, dict) in collectGuestInfoPlists(in: sharedRoot, depth: 0, visited: &walked) {
                            let uuid = (uuidPath as NSString).lastPathComponent
                            guard guestsByUUID[uuid] == nil else { continue }
                            let plistName = nameFromContainerInfo(dict)
                            let appIdentifier = dict["appIdentifier"] as? String
                            let appRef = appIdentifier.flatMap { lookupAppByBundleId($0, in: sharedAppsRoot) }
                                ?? lookupAppByUUID(uuid, in: sharedAppsRoot)
                            let bundleId = appRef?.bundleId ?? appIdentifier ?? uuid
                            let displayName = appRef?.displayName ?? plistName ?? uuid
                            let key = makeKey(bundleId: bundleId, uuid: uuid)
                            guestsByUUID[uuid] = LiveContainerGuest(
                                id: key,
                                bundleIdentifier: bundleId,
                                displayName: displayName,
                                containerPath: uuidPath,
                                iconData: appRef?.iconData,
                                hostName: host.name,
                                isShared: true
                            )
                        }
                    }

                    return Array(guestsByUUID.values).sorted {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    }
                }

                if SandboxEscape.lcContainerExtensionsActive {
                    guests = try runEnumeration()
                } else {
                    guests = try escape.withHandle(for: host.containerPath) { _ in try runEnumeration() }
                }
            } catch {
                return LiveContainerInstance(host: host, guests: [], error: error.localizedDescription)
            }
            return LiveContainerInstance(host: host, guests: guests, error: nil)
        }

        // The AppGroup shared container is visible to every LiveContainer instance,
        // so the same converted app may be enumerated once per host. Keep only one
        // representative and prefer the entry that has a real app name/icon.
        return dedupeSharedGuestsAcrossHosts(instances)
    }

    // MARK: - Global shared-container dedupe

    private func dedupeSharedGuestsAcrossHosts(_ instances: [LiveContainerInstance]) -> [LiveContainerInstance] {
        guard instances.count > 1,
              let agRoot = SandboxEscape.lcAppGroupPath else { return instances }
        let sharedPrefix = (agRoot as NSString).appendingPathComponent("LiveContainer/Data/Application")

        var bestByUUID: [String: (guest: LiveContainerGuest, hostIndex: Int)] = [:]
        for (i, instance) in instances.enumerated() {
            for guest in instance.guests where guest.containerPath.hasPrefix(sharedPrefix) {
                let uuid = (guest.containerPath as NSString).lastPathComponent
                if let existing = bestByUUID[uuid] {
                    if guestHasBetterMetadata(guest, than: existing.guest) {
                        bestByUUID[uuid] = (guest, i)
                    }
                } else {
                    bestByUUID[uuid] = (guest, i)
                }
            }
        }
        guard !bestByUUID.isEmpty else { return instances }

        let preferredHostIndex = bestByUUID.values.map { $0.hostIndex }.min() ?? 0

        return instances.enumerated().compactMap { (i, instance) in
            let kept: [LiveContainerGuest]
            if i == preferredHostIndex {
                kept = instance.guests.filter {
                    if !$0.containerPath.hasPrefix(sharedPrefix) { return true }
                    let uuid = ($0.containerPath as NSString).lastPathComponent
                    return bestByUUID[uuid]?.hostIndex == i
                }
            } else {
                kept = instance.guests.filter { !$0.containerPath.hasPrefix(sharedPrefix) }
            }
            guard !kept.isEmpty else { return nil }
            return LiveContainerInstance(host: instance.host, guests: kept, error: instance.error)
        }
    }

    private func guestHasBetterMetadata(_ a: LiveContainerGuest, than b: LiveContainerGuest) -> Bool {
        let aUUID = (a.containerPath as NSString).lastPathComponent
        let bUUID = (b.containerPath as NSString).lastPathComponent
        let aHasRealName = a.displayName != aUUID
        let bHasRealName = b.displayName != bUUID
        if aHasRealName != bHasRealName { return aHasRealName }
        let aHasIcon = a.iconData != nil && !a.iconData!.isEmpty
        let bHasIcon = b.iconData != nil && !b.iconData!.isEmpty
        if aHasIcon != bHasIcon { return aHasIcon }
        return false
    }

    // MARK: - `.app` enumeration

    private struct GuestBundle {
        let folderName: String           // `<uuid or display>.app` minus `.app`
        let bundleId: String
        let displayName: String
        let iconData: Data?
        let dataUUIDs: [String]         // from LCAppInfo.plist
        let appBundlePath: String
    }

    private func enumerateGuestBundles(root: String) -> [GuestBundle] {
        guard files.isDirectory(at: root) else { return [] }
        let entries = (try? files.list(directory: root)) ?? []
        var bundles: [GuestBundle] = []
        for entry in entries where entry.isDirectory {
            let appPath = entry.path
            // LiveContainer stores shared ("converted") guest `.app` bundles in
            // the AppGroup's Applications folder using the bare bundle id as the
            // folder name (no `.app` suffix), so accept any directory that
            // carries an Info.plist as a candidate app bundle.
            let hasAppSuffix = entry.name.hasSuffix(".app")
            let isBundleLike = hasAppSuffix
                || files.exists(at: (appPath as NSString).appendingPathComponent("Info.plist"))
            guard isBundleLike else { continue }
            let folderName = hasAppSuffix ? (entry.name as NSString).deletingPathExtension : entry.name

            guard let info = readPlist(at: (appPath as NSString).appendingPathComponent("Info.plist"))
            else { continue }
            let bundleId = (info["CFBundleIdentifier"] as? String) ?? folderName
            let displayName = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? folderName
            let iconData = loadIconData(bundlePath: appPath, info: info)
            let dataUUIDs = readDataUUIDs(appPath: appPath)
            bundles.append(GuestBundle(
                folderName: folderName,
                bundleId: bundleId,
                displayName: displayName,
                iconData: iconData,
                dataUUIDs: dataUUIDs,
                appBundlePath: appPath
            ))
        }
        return bundles
    }

    private func lookupAppByUUID(_ uuid: String, in appsRoot: String) -> GuestBundle? {
        enumerateGuestBundles(root: appsRoot).first { $0.dataUUIDs.contains(uuid) }
            ?? enumerateGuestBundles(root: appsRoot).first { $0.folderName == uuid }
    }

    private func lookupAppByBundleId(_ bundleId: String, in appsRoot: String) -> GuestBundle? {
        enumerateGuestBundles(root: appsRoot).first { $0.bundleId == bundleId }
    }

    /// Read `LCAppInfo.plist` and return every UUID that points at a guest
    /// container for this `.app`. `LCDataUUID` is the primary container; the
    /// `LCContainers` array (when present) lists per-account extras.
    private func readDataUUIDs(appPath: String) -> [String] {
        guard let lc = readPlist(at: (appPath as NSString).appendingPathComponent("LCAppInfo.plist"))
        else { return [] }
        var uuids: [String] = []
        if let primary = lc["LCDataUUID"] as? String, !primary.isEmpty {
            uuids.append(primary)
        }
        if let arr = lc["LCContainers"] as? [[String: Any]] {
            for entry in arr {
                if let folder = entry["folderName"] as? String, !folder.isEmpty {
                    uuids.append(folder)
                }
            }
        }
        return Array(Set(uuids))
    }

    // MARK: - LCContainerInfo.plist walk (fallback)

    private func collectGuestInfoPlists(
        in directory: String,
        depth: Int,
        visited: inout [String]
    ) -> [(String, [String: Any])] {
        let maxDepth = 2
        let std = (directory as NSString).standardizingPath
        guard depth <= maxDepth, !visited.contains(std) else { return [] }
        visited.append(std)

        let infoPath = (directory as NSString).appendingPathComponent("LCContainerInfo.plist")
        if files.exists(at: infoPath) {
            if let data = try? files.readFile(at: infoPath),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return [(directory, dict)]
            }
            return []
        }

        let children = (try? files.list(directory: directory)) ?? []
        var collected: [(String, [String: Any])] = []
        for child in children where child.isDirectory {
            collected.append(contentsOf: collectGuestInfoPlists(in: child.path, depth: depth + 1, visited: &visited))
        }
        return collected
    }

    private func nameFromContainerInfo(_ dict: [String: Any]) -> String? {
        for key in ["name", "displayName", "appName", "title", "containerName"] {
            if let v = dict[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: - Plist + icon helpers

    private func readPlist(at path: String) -> [String: Any]? {
        guard let data = try? files.readFile(at: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Try the standard iOS icon keys, then fall back to the largest PNG
    /// inside the bundle so we still surface something for hand-rolled apps.
    private func loadIconData(bundlePath: String, info: [String: Any]) -> Data? {
        var candidates: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            if let files = primary["CFBundleIconFiles"] as? [String] { candidates.append(contentsOf: files) }
            if let name = primary["CFBundleIconName"] as? String { candidates.append(name) }
        }
        if let files = info["CFBundleIconFiles"] as? [String] { candidates.append(contentsOf: files) }
        if let name = info["CFBundleIconName"] as? String { candidates.append(name) }

        for name in candidates {
            for suffix in ["@3x", "@2x", ""] {
                let path = (bundlePath as NSString).appendingPathComponent("\(name)\(suffix).png")
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
                    return data
                }
            }
        }

        let contents = (try? fm.contentsOfDirectory(atPath: bundlePath)) ?? []
        let pngs = contents.filter { $0.lowercased().hasSuffix(".png") }
        var best: (size: Int, data: Data)?
        for png in pngs {
            let full = (bundlePath as NSString).appendingPathComponent(png)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let size = (attrs[.size] as? NSNumber)?.intValue else { continue }
            if best == nil || size > best!.size {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: full)), !data.isEmpty {
                    best = (size, data)
                }
            }
        }
        return best?.data
    }

    private func looksLikeUUID(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        return s.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil
    }
}