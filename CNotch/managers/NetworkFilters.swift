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
/// Read from the system's own database rather than by shelling out to
/// `systemextensionsctl`, which is not only a subprocess but actually hides
/// some of this: it prints an extension under one category heading, so a
/// filter that registers as *both* endpoint security and network extension is
/// listed only under the former, and reads as "not a network filter".
enum NetworkFilters {
    struct Filter: Identifiable, Equatable {
        /// The bundle identifier.
        let id: String
        /// What to actually show: the vendor, read from the staged bundle.
        let name: String
        let version: String
        let isEnabled: Bool
        let isRunning: Bool

        /// Registered and switched on, but nothing is there to answer for it.
        /// Worth calling out separately: this is the state that looks fine
        /// everywhere else.
        var isOrphaned: Bool { isEnabled && !isRunning }
    }

    private static let databaseURL = URL(fileURLWithPath: "/Library/SystemExtensions/db.plist")
    private static let networkCategory = "com.apple.system_extension.network_extension"

    static func current() -> [Filter] {
        guard let data = try? Data(contentsOf: databaseURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let extensions = (root as? [String: Any])?["extensions"] as? [[String: Any]]
        else { return [] }

        let running = runningExecutablePaths()
        let names = displayNames()
        return extensions.compactMap { entry -> Filter? in
            guard let identifier = entry["identifier"] as? String,
                  let categories = entry["categories"] as? [String],
                  categories.contains(networkCategory)
            else { return nil }
            let version = (entry["bundleVersion"] as? [String: Any])?["CFBundleShortVersionString"] as? String
            return Filter(
                id: identifier,
                name: names[identifier].map(shorten) ?? identifier,
                version: version ?? "",
                isEnabled: (entry["state"] as? String) == "activated_enabled",
                // A staged extension's executable lives at a path containing
                // its bundle identifier, so that's enough to match on without
                // resolving each bundle.
                isRunning: running.contains { $0.contains(identifier) }
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// `db.plist` stores no readable name, only the identifier, so the name
    /// comes from each staged bundle's own Info.plist.
    private static func displayNames() -> [String: String] {
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

    /// Every one of these names ends in "... Extension", which is what the
    /// section heading already says. Drop it and keep the vendor, so the row
    /// reads "AdGuard" rather than "AdGuard Network Extension".
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
