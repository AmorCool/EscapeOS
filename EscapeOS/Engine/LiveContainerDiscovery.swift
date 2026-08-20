import Foundation

/// A LiveContainer instance found among the device's installed apps, together
/// with the guest apps it hosts inside its own Data container.
struct LiveContainerInstance: Identifiable {
    let id = UUID()
    let host: InstalledApp
    let guests: [InstalledApp]
    let error: String?
}

/// Discovers apps installed *inside* LiveContainer — the "guest" apps that
/// LiveContainer sideloads into its own Data container.
///
/// LiveContainer keeps each guest app's data at:
///   <LiveContainer Data container>/Documents/Data/Application/<UUID>/
/// (older builds used Documents/Data/<UUID> directly)
/// where every `<UUID>` holds an `LCContainerInfo.plist` describing the guest
/// (`appIdentifier`, `name`). That `<UUID>` directory is a standard iOS app
/// container, so `ReclaimService` — which only needs an `InstalledApp` with a
/// `containerPath` — works unchanged once we surface each guest as an
/// `InstalledApp` whose container points at the `<UUID>` directory.
///
/// We scan Documents/Data recursively (max depth 2) so both the current
/// "Application/<UUID>" layout and the flat "<UUID>" layout are found.
/// Shared containers (kept in an App Group outside this container) are not
/// reachable through the LiveContainer Data container and are skipped.
final class LiveContainerDiscovery {

    private let escape = SandboxEscape()
    private let files = FileService()

    /// Bundle-id prefixes that identify a LiveContainer instance. Covers the
    /// primary app and the alternate instances (livecontainer2, livecontainer3…).
    private let prefixes = ["com.kdt.livecontainer"]

    /// Discover every guest app across all installed LiveContainer instances.
    /// - Parameter installedApps: the full system app list (includes LiveContainer).
    func discover(installedApps: [InstalledApp]) -> [LiveContainerInstance] {
        let hosts = installedApps.filter { app in
            prefixes.contains(where: { app.bundleIdentifier.lowercased().hasPrefix($0) })
        }
        guard !hosts.isEmpty else { return [] }

        return hosts.compactMap { host in
            let dataRoot = (host.containerPath as NSString).appendingPathComponent("Documents/Data")
            let guests: [InstalledApp]
            do {
                // Open the LiveContainer Data container (class 13 path-traversal
                // route, same as Reclaim) and read each guest's info plist.
                guests = try escape.withHandle(for: host.containerPath) { _ in
                    try self.readGuests(dataRoot: dataRoot, host: host)
                }
            } catch {
                return LiveContainerInstance(host: host, guests: [], error: error.localizedDescription)
            }
            return LiveContainerInstance(host: host, guests: guests, error: nil)
        }
    }

    private func readGuests(dataRoot: String, host: InstalledApp) throws -> [InstalledApp] {
        guard files.isDirectory(at: dataRoot) else { return [] }
        var result: [InstalledApp] = []
        var visited: Set<String> = []
        collectGuests(in: dataRoot, depth: 0, host: host, into: &result, visited: &visited)
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Walk `directory` looking for `LCContainerInfo.plist`. A directory that
    /// contains one is a guest container and is surfaced as an `InstalledApp`.
    /// Otherwise we descend into its subdirectories (up to `maxDepth` levels)
    /// so both layouts — `Documents/Data/Application/<UUID>` and the flat
    /// `Documents/Data/<UUID>` — are discovered.
    private func collectGuests(
        in directory: String,
        depth: Int,
        host: InstalledApp,
        into result: inout [InstalledApp],
        visited: inout Set<String>
    ) {
        let maxDepth = 2
        let std = (directory as NSString).standardizingPath
        guard depth <= maxDepth, visited.insert(std).inserted else { return }

        let infoPath = (directory as NSString).appendingPathComponent("LCContainerInfo.plist")
        if files.exists(at: infoPath) {
            if let guest = makeGuest(infoPath: infoPath, uuidPath: directory, host: host) {
                result.append(guest)
            }
            return
        }

        guard let children = try? files.list(directory: directory) else { return }
        for child in children where child.isDirectory {
            collectGuests(in: child.path, depth: depth + 1, host: host, into: &result, visited: &visited)
        }
    }

    private func makeGuest(infoPath: String, uuidPath: String, host: InstalledApp) -> InstalledApp? {
        guard let data = try? files.readFile(at: infoPath),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let guestBundle = (dict["appIdentifier"] as? String) ?? (uuidPath as NSString).lastPathComponent
        let guestName = (dict["name"] as? String) ?? (uuidPath as NSString).lastPathComponent
        // The same guest bundle id may be hosted by more than one
        // LiveContainer instance, so namespace the cache/selection key.
        let cacheKey = "\(host.bundleIdentifier)::\(guestBundle)"
        return InstalledApp(
            bundleIdentifier: cacheKey,
            name: guestName,
            containerPath: uuidPath,
            version: nil
        )
    }
}
