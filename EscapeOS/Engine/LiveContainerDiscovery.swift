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
///   <LiveContainer Data container>/Documents/Data/<UUID>/
/// where every `<UUID>` holds an `LCContainerInfo.plist` describing the guest
/// (`appIdentifier`, `name`). That `<UUID>` directory is a standard iOS app
/// container, so `ReclaimService` — which only needs an `InstalledApp` with a
/// `containerPath` — works unchanged once we surface each guest as an
/// `InstalledApp` whose container points at the `<UUID>` directory.
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
        let entries = try files.list(directory: dataRoot).filter { $0.isDirectory }
        var result: [InstalledApp] = []
        for entry in entries {
            let uuidPath = entry.path
            let infoPath = (uuidPath as NSString).appendingPathComponent("LCContainerInfo.plist")
            guard files.isDirectory(at: uuidPath), files.exists(at: infoPath) else { continue }
            guard let data = try? files.readFile(at: infoPath),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }

            let guestBundle = (dict["appIdentifier"] as? String) ?? entry.name
            let guestName = (dict["name"] as? String) ?? entry.name
            // The same guest bundle id may be hosted by more than one
            // LiveContainer instance, so namespace the cache/selection key.
            let cacheKey = "\(host.bundleIdentifier)::\(guestBundle)"
            result.append(InstalledApp(
                bundleIdentifier: cacheKey,
                name: guestName,
                containerPath: uuidPath,
                version: nil
            ))
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
