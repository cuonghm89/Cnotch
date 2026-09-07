//
//  ScreenshotWatcher.swift
//  CNotch
//
//  Watches the user's screenshot folder (wherever screencapture is
//  configured to save, defaulting to the Desktop) and surfaces quick
//  actions on the notch when a new screenshot appears.
//

import AppKit
import Defaults

final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    private var source: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1
    private var isRunning = false
    private var startedAt = Date()

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "heic"]

    private var screenshotDirectory: URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (custom as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startedAt = Date()

        let directory = screenshotDirectory
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { isRunning = false; return }
        watchedDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.checkForNewScreenshot(in: directory)
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
    }

    private func checkForNewScreenshot(in directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let recentCutoff = Date().addingTimeInterval(-3)
        let candidate = contents
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (url, date)
            }
            .filter { $0.1 > max(recentCutoff, startedAt) }
            .max { $0.1 < $1.1 }

        guard let (url, _) = candidate else { return }

        Task { @MainActor in
            guard Defaults[.screenshotQuickActionsEnabled] else { return }
            CNotchViewCoordinator.shared.toggleExpandingView(
                status: true,
                type: .screenshot,
                title: "Screenshot",
                subtitle: url.lastPathComponent,
                icon: "camera.viewfinder",
                url: url
            )
        }
    }
}
