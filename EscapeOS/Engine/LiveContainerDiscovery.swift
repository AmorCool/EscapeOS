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
    /// Cache key scoped to the host LC instance (the same bundle id may be
    /// hosted by more than one LC instance).
    let id: String
    /// Guest app bundle identifier (from LCContainerInfo.plist `appIdentifier`).
    let bundleIdentifier: String
    /// Real display name — preferred order:
    ///   1. `LCContainerInfo.plist` `name` / `displayName` / `appName`
    ///   2. guest `.app` `Info.plist` `CFBundleDisplayName` / `CFBundleName`
    ///   3. guest bundle identifier (last resort)
    let displayName: String
    /// Path to the guest's UUID directory inside LiveContainer. This is what
    /// `ReclaimService` operates on as if it were a normal app container.
    let containerPath: String
    /// Raw bytes of the guest app icon (already decoded inside the sandbox
    /// extension so the UI does not need to reopen the container). Nil when
    /// the bundle did not ship an icon we could locate.
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
/// Layout (current LiveContainer source: LiveContainerSwiftUI/LCContainer.swift):
///   <LiveContainer Data container>/Documents/Applications/<name>.app/   (guest binary)
///   <LiveContainer Data container>/Documents/Data/Application/<UUID>/    (guest sandbox)
///                                                       └─ LCContainerInfo.plist
/// (older builds used Documents/Data/<UUID>/ directly)
/// Shared containers live in an App Group outside this container and are not
/// reachable through the LiveContainer Data container, so they are skipped.
final class LiveContainerDiscovery {

    private let escape = SandboxEscape()
    private let files = FileService()
    private let fm = FileManager.default

    /// Bundle-id prefixes that identify a LiveContainer instance. Covers the
    /// primary app and the alternate instances (livecontainer2, livecontainer3…).
    private let prefixes = ["com.kdt.livecontainer"]

    /// Discover every guest app across all installed LiveContainer instances.
    func discover(installedApps: [InstalledApp]) -> [LiveContainerInstance] {
        let hosts = installedApps.filter { app in
            prefixes.contains(where: { app.bundleIdentifier.lowercased().hasPrefix($0) })
        }
        guard !hosts.isEmpty else { return [] }

        return hosts.compactMap { host in
            let guests: [LiveContainerGuest]
            do {
                // Open the LC Data container once. All listing + reading inside
                // this closure goes through the consumed sandbox extension.
                guests = try escape.withHandle(for: host.containerPath) { _ in
                    let appsRoot = (host.containerPath as NSString).appendingPathComponent("Documents/Applications")
                    let applications = readApplicationsIndex(root: appsRoot)
                    let dataRoot = (host.containerPath as NSString).appendingPathComponent("Documents/Data")
                    var visited: [String] = []
                    let infos = collectGuestInfoPlists(in: dataRoot, depth: 0, visited: &visited)
                    return infos.compactMap { (uuidPath, dict) in
                        let appId = (dict["appIdentifier"] as? String) ?? (uuidPath as NSString).lastPathComponent
                        let plistName = nameFromContainerInfo(dict)
                        let entry = applications[appId]
                        let name = plistName ?? entry?.displayName ?? appId
                        let key = "\(host.bundleIdentifier)::\(appId)"
                        return LiveContainerGuest(
                            id: key,
                            bundleIdentifier: appId,
                            displayName: name,
                            containerPath: uuidPath,
                            iconData: entry?.iconData,
                            hostName: host.name
                        )
                    }
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                }
            } catch {
                return LiveContainerInstance(host: host, guests: [], error: error.localizedDescription)
            }
            return LiveContainerInstance(host: host, guests: guests, error: nil)
        }
    }

    // MARK: - Applications index (real names + icons)

    private struct AppIndexEntry {
        let displayName: String
        let iconData: Data?
    }

    /// Walk Documents/Applications once, returning a map keyed by
    /// `CFBundleIdentifier`. Each entry carries a real display name
    /// (from Info.plist) and pre-loaded icon bytes.
    private func readApplicationsIndex(root: String) -> [String: AppIndexEntry] {
        guard files.isDirectory(at: root) else { return [:] }
        let entries = (try? files.list(directory: root)) ?? []
        var map: [String: AppIndexEntry] = [:]
        for entry in entries where entry.isDirectory && entry.name.hasSuffix(".app") {
            let appPath = entry.path
            let infoPath = (appPath as NSString).appendingPathComponent("Info.plist")
            guard let data = try? files.readFile(at: infoPath),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            guard let bundleId = dict["CFBundleIdentifier"] as? String, !bundleId.isEmpty else { continue }
            let displayName = (dict["CFBundleDisplayName"] as? String)
                ?? (dict["CFBundleName"] as? String)
                ?? (entry.name as NSString).deletingPathExtension
            let iconData = loadIconData(bundlePath: appPath, info: dict)
            map[bundleId] = AppIndexEntry(displayName: displayName, iconData: iconData)
        }
        return map
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

        // Last resort: pick the largest PNG inside the bundle.
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

    // MARK: - Guest container walk

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

    /// `LCContainerInfo.plist` is generated by LiveContainer and historically
    /// uses a `name` key, but forks / older builds vary. Try several.
    private func nameFromContainerInfo(_ dict: [String: Any]) -> String? {
        for key in ["name", "displayName", "appName", "title", "containerName"] {
            if let v = dict[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }
}