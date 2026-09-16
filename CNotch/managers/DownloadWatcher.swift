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
    private var pendingAnnouncements: [URL] = []
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
        // open() on a TCC-protected folder blocks in the kernel until the user
        // answers the permission prompt -- and that prompt is drawn by the main
        // thread, so opening it here would deadlock the app against itself: the
        // UI never appears, so the prompt never appears, so open() never
        // returns. Do it off the main thread and hop back with the result.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let descriptor = open(directory.path, O_EVTONLY)
            DispatchQueue.main.async {
                guard let self, self.isRunning else {
                    if descriptor >= 0 { close(descriptor) }
                    return
                }
                guard descriptor >= 0 else { self.isRunning = false; return }
                self.watchedDescriptor = descriptor

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
        }
    }

    func stop() {
        isRunning = false
        source?.cancel()
        source = nil
        announcementTask?.cancel()
        announcementTask = nil
        pendingAnnouncements.removeAll()
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

    /// One popup per file, in sequence -- the notch has a single slot, so they
    /// queue. New arrivals are appended to that queue rather than replacing it:
    /// cancelling the running task instead, as this used to, cut the popup that
    /// was on screen short and dropped it entirely whenever a second file
    /// landed while the first was still showing.
    private func announce(_ urls: [URL]) {
        pendingAnnouncements.append(contentsOf: urls)
        guard announcementTask == nil else { return }
        announcementTask = Task { @MainActor in
            while !pendingAnnouncements.isEmpty {
                guard !Task.isCancelled else { break }
                let url = pendingAnnouncements.removeFirst()
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
            announcementTask = nil
        }
    }
}
