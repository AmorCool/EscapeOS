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

    /// Synthesized `InstalledApp` so the existing `ReclaimService.scan /
    /// .reclaim` can treat this guest exactly like a system app.
    var installedApp: InstalledApp {
        InstalledApp(
            bundleIdentifier: id,
            name: displayName,
            containerPath: containerPath,
            version: nil
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
        let hosts = installedApps.filter { app in
            prefixes.contains(where: { app.bundleIdentifier.lowercased().hasPrefix($0) })
        }
        guard !hosts.isEmpty else { return [] }

        return hosts.compactMap { host in
            let guests: [LiveContainerGuest]
            do {
                guests = try escape.withHandle(for: host.containerPath) { _ in
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

                    // Fallback: scan LCContainerInfo.plist files we might have
                    // missed (older / fork layouts that don't carry LCAppInfo).
                    // We walk both the private `Documents/Data/...` tree and the
                    // `Documents/Shared/Data/...` tree (LiveContainer stores
                    // shared-guest containers under Shared/) so apps that were
                    // "Shared" via LiveContainer's Share App flow still surface.
                    let sharedRoot = (host.containerPath as NSString)
                        .appendingPathComponent("Documents/Shared/Data")
                    var walked: [String] = []
                    for root in [dataRoot, sharedRoot] {
                        for (uuidPath, dict) in collectGuestInfoPlists(in: root, depth: 0, visited: &walked) {
                            let uuid = (uuidPath as NSString).lastPathComponent
                            // Dedupe against the primary pass — same UUID = same guest.
                            guard guestsByUUID[uuid] == nil else { continue }
                            let plistName = nameFromContainerInfo(dict)
                            // Try to find a matching `.app` via the LCAppInfo.plist
                            // folderName → app link (some LC forks keep this).
                            let appRef = lookupAppByUUID(uuid, in: appsRoot)
                            let bundleId = appRef?.bundleId ?? uuid
                            let displayName = plistName ?? appRef?.displayName ?? uuid
                            let key = makeKey(bundleId: bundleId, uuid: uuid)
                            let sharedTag = root == sharedRoot && appRef == nil
                            guestsByUUID[uuid] = LiveContainerGuest(
                                id: key,
                                bundleIdentifier: bundleId,
                                displayName: displayName,
                                containerPath: uuidPath,
                                iconData: appRef?.iconData,
                                hostName: sharedTag ? "\(host.name) (共享)" : host.name
                            )
                        }
                    }
                    return Array(guestsByUUID.values).sorted {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    }
                }
            } catch {
                return LiveContainerInstance(host: host, guests: [], error: error.localizedDescription)
            }
            return LiveContainerInstance(host: host, guests: guests, error: nil)
        }
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
        for entry in entries where entry.isDirectory && entry.name.hasSuffix(".app") {
            let appPath = entry.path
            let folderName = (entry.name as NSString).deletingPathExtension

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