//
//  NetworkFilters.swift
//  CNotch
//
//  Which network filters are sitting in the connection path, and whether each
//  one is actually running.
//

import Darwin
import Foundation

/// macOS gives you no single place to see this. Its own Login Items &
/// Extensions screen shows what is *registered*, which is not the same thing:
/// an app whose filter is switched off in its own UI still has its extension
/// loaded and filtering, and an app dragged to the Trash without running its
/// uninstaller leaves the extension registered as enabled with nothing behind
/// it. Both states look identical there, and both break connections in ways
/// the Wi-Fi menu shows as a perfectly healthy network.
///
/// Nothing here is keyed to a particular vendor -- whatever a machine has
/// installed is what it lists, and machines with none show no section at all.
///
/// There are two ways to ship a network provider on macOS, and a machine can
/// have both, so both are read:
///
/// - A **system extension**, staged under /Library/SystemExtensions and listed
///   in the system's own database. Read that database rather than shelling out
///   to `systemextensionsctl`, which is not only a subprocess but actually
///   hides some of this: it prints an extension under a single category
///   heading, so a filter registering as both endpoint security and network
///   extension is listed only under the former and reads as "not a network
///   filter".
/// - An **app extension** bundled inside the app itself, the older mechanism
///   still used by most VPN clients. These appear in no extension database at
///   all, so they are found by looking for the `.appex` bundles that declare a
///   NetworkExtension extension point.
enum NetworkFilters {
    enum Status: Equatable, Sendable {
        /// Loaded, with a process behind it.
        case enabled
        /// Registered and switched on, but nothing is there to answer for it.
        /// Worth calling out separately: this is the state that looks fine
        /// everywhere else.
        case orphaned
        /// Switched off.
        case off
        /// Present on disk but not currently running -- a VPN client that
        /// isn't connected, say.
        case installed
    }

    struct Filter: Identifiable, Equatable, Sendable {
        let id: String
        /// What to show: the vendor, not the bundle identifier.
        let name: String
        let status: Status
    }

    static func current() -> [Filter] {
        let running = runningExecutablePaths()
        let extensions = systemExtensions(running: running)
        // An app shipping both mechanisms would otherwise be listed twice.
        let alreadyListed = Set(extensions.map(\.name))
        let apps = appExtensions(running: running).filter { !alreadyListed.contains($0.name) }
        return (extensions + apps).sorted { $0.name < $1.name }
    }

    // MARK: - System extensions

    private static let databaseURL = URL(fileURLWithPath: "/Library/SystemExtensions/db.plist")
    private static let networkCategory = "com.apple.system_extension.network_extension"

    private static func systemExtensions(running: [String]) -> [Filter] {
        guard let data = try? Data(contentsOf: databaseURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let entries = (root as? [String: Any])?["extensions"] as? [[String: Any]]
        else { return [] }

        let names = stagedDisplayNames()
        return entries.compactMap { entry -> Filter? in
            guard let identifier = entry["identifier"] as? String,
                  let categories = entry["categories"] as? [String],
                  categories.contains(networkCategory),
                  let state = entry["state"] as? String,
                  // Upgrading leaves the previous version in the database as
                  // `terminated_waiting_to_uninstall_on_reboot` until the next
                  // restart. It shares its identifier with the new one, so it
                  // matched the same running process and the list showed one
                  // product twice -- the second row reading "Off", which is
                  // not what is happening to it. Only states that begin
                  // `activated` are in the path at all.
                  state.hasPrefix("activated")
            else { return nil }

            let isEnabled = state == "activated_enabled"
            // A staged extension's executable lives at a path containing its
            // bundle identifier, so that's enough to match on.
            let isRunning = running.contains { $0.contains(identifier) }
            return Filter(
                id: identifier,
                name: names[identifier].map(shorten) ?? identifier,
                status: isEnabled ? (isRunning ? .enabled : .orphaned) : .off
            )
        }
    }

    /// `db.plist` stores no readable name, only the identifier, so the name
    /// comes from each staged bundle's own Info.plist.
    private static func stagedDisplayNames() -> [String: String] {
        let root = URL(fileURLWithPath: "/Library/SystemExtensions")
        guard let staged = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [:] }

        var names: [String: String] = [:]
        for folder in staged {
            guard let bundles = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            ) else { continue }
            for bundle in bundles where bundle.pathExtension == "systemextension" {
                guard let info = Bundle(url: bundle)?.infoDictionary,
                      let identifier = info["CFBundleIdentifier"] as? String,
                      let display = info["CFBundleDisplayName"] as? String
                else { continue }
                names[identifier] = display
            }
        }
        return names
    }

    // MARK: - App extensions

    /// One row per app, not per provider: a VPN client typically ships a
    /// separate tunnel for each protocol it speaks, and listing three rows for
    /// one app would say nothing extra.
    private static func appExtensions(running: [String]) -> [Filter] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        var byApp: [String: Bool] = [:]
        for root in roots {
            let apps = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            )) ?? []
            for app in apps where app.pathExtension == "app" {
                let plugins = app.appendingPathComponent("Contents/PlugIns")
                let bundles = (try? FileManager.default.contentsOfDirectory(
                    at: plugins, includingPropertiesForKeys: nil
                )) ?? []
                for appex in bundles where appex.pathExtension == "appex" {
                    guard let info = Bundle(url: appex)?.infoDictionary,
                          let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                          point.contains("networkextension")
                    else { continue }
                    let name = app.deletingPathExtension().lastPathComponent
                    // Matched on the bundle's path, not its identifier: an
                    // appex executable is named after the bundle, so
                    // "PacketTunnel.appex/Contents/MacOS/PacketTunnel" never
                    // contains "com.vendor.app.KSPacketTunnel" and a running
                    // tunnel always read as idle.
                    let prefix = appex.path + "/"
                    let isRunning = running.contains { $0.hasPrefix(prefix) }
                    byApp[name] = (byApp[name] ?? false) || isRunning
                }
            }
        }
        return byApp.map { Filter(id: $0.key, name: $0.key, status: $0.value ? .enabled : .installed) }
    }

    // MARK: - Shared

    /// Every staged extension's name ends in "... Extension", which is what
    /// the section heading already says. Drop it and keep the vendor, so the
    /// row reads "AdGuard" rather than "AdGuard Network Extension".
    private static func shorten(_ name: String) -> String {
        for suffix in [" Network Extension", " System Extension", " Extension"] where name.hasSuffix(suffix) {
            let trimmed = String(name.dropLast(suffix.count))
            if !trimmed.isEmpty { return trimmed }
        }
        return name
    }

    private static func runningExecutablePaths() -> [String] {
        var size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size)
        size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, size)
        guard size > 0 else { return [] }

        var paths: [String] = []
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // = PROC_PIDPATHINFO_MAXSIZE
        for pid in pids where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            paths.append(String(cString: buffer))
        }
        return paths
    }
}
