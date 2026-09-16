//
//  DownloadWatcher.swift
//  CNotch
//
//  Watches the Downloads folder and surfaces the same quick actions on the
//  notch that a new screenshot gets.
//

import AppKit
import Defaults

/// There is deliberately no progress bar here. A browser downloads into a
/// temporary file and only creates the real one once it has finished --
/// `.crdownload` in Chrome, `.part` in Firefox, a `.download` package in
/// Safari -- so ignoring those temporary names IS the "finished" signal, with
/// nothing to poll and no per-browser guesswork. Following progress instead
/// would mean cracking open Safari's package to read a total out of its plist
/// while Chrome exposes no total at all.
final class DownloadWatcher {
    static let shared = DownloadWatcher()

    private var source: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1
    private var isRunning = false
    private var startedAt = Date()
    private var announcedPaths: Set<String> = []
    private var announcementTask: Task<Void, Never>?

    /// Partial downloads, plus the generic temporary names an app might rename
    /// away from once it's done writing.
    private static let inProgressExtensions: Set<String> = [
        "download", "crdownload", "opdownload", "part", "partial", "tmp", "temp"
    ]

    private var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startedAt = Date()

        let directory = downloadsDirectory
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { isRunning = false; return }
        watchedDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.checkForNewDownload(in: directory)
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchedDescriptor, fd >= 0 { close(fd) }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        isRunning = false
        source?.cancel()
        source = nil
        announcementTask?.cancel()
        announcedPaths.removeAll()
    }

    private func checkForNewDownload(in directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let recentCutoff = Date().addingTimeInterval(-3)
        // Collect every recent, not-yet-announced file rather than only the
        // newest, the same way screenshots do: two downloads finishing within
        // a few seconds of each other would otherwise lose the popup for
        // whichever isn't the latest by modification date.
        let candidates = contents
            .filter { !Self.inProgressExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                      values.isDirectory != true,
                      let date = values.contentModificationDate
                else { return nil }
                return (url, date)
            }
            .filter { $0.1 > max(recentCutoff, startedAt) && !announcedPaths.contains($0.0.path) }
            .sorted { $0.1 < $1.1 }

        guard !candidates.isEmpty else { return }
        for (url, _) in candidates { announcedPaths.insert(url.path) }
        announce(candidates.map(\.0))
    }

    /// One popup per download, in sequence -- the notch has a single slot.
    private func announce(_ urls: [URL]) {
        announcementTask?.cancel()
        announcementTask = Task { @MainActor in
            for url in urls {
                guard !Task.isCancelled else { return }
                guard Defaults[.enableDownloadListener], !CNotchViewCoordinator.shared.isScreenLocked else { continue }
                CNotchViewCoordinator.shared.toggleExpandingView(
                    status: true,
                    type: .download,
                    title: "Downloaded",
                    subtitle: url.lastPathComponent,
                    icon: "arrow.down.circle",
                    url: url
                )
                try? await Task.sleep(nanoseconds: 6_500_000_000)
            }
        }
    }
}
