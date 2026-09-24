//
//  QuickScreenshot.swift
//  CNotch
//
//  Take a screenshot from a shortcut, decide afterwards what to do with it.
//

import AppKit
import Defaults
import Foundation
import os

/// macOS already has Cmd-Shift-3 and Cmd-Shift-4, and this does not try to
/// replace them. What it changes is the order of the questions.
///
/// The system shortcut decides for you: the file is written to one fixed
/// folder before you have seen it, and a shot you only wanted to paste into a
/// message leaves a file behind to tidy up later. Here the shot lands in a
/// temporary file, the notch shows it, and *then* you say what it was for --
/// copy it and it never reaches the disk at all; save or edit it and it goes
/// to a folder you chose.
///
/// Ignoring the strip saves it, which is what the system does and therefore
/// what muscle memory expects.
///
/// The capture itself is `screencapture(8)`, not ScreenCaptureKit: it is the
/// same crosshair, with the same space-bar-to-pick-a-window and the same Esc
/// to give up, and reimplementing that faithfully would be a great deal of
/// code to arrive back where we started.
@MainActor
final class QuickScreenshot {
    static let shared = QuickScreenshot()

    enum Mode {
        /// Drag a rectangle, or press space to take a window.
        case region
        /// Everything, no selection step.
        case fullScreen

        var arguments: [String] {
            switch self {
            // -o drops the window shadow when the space bar picks a window.
            case .region: ["-i", "-o"]
            // -x is silent: the capture happens with no selection step, and a
            // shutter sound with nothing preceding it is startling.
            case .fullScreen: ["-x"]
            }
        }
    }

    /// A queue of its own. `screencapture -i` sits there for as long as the
    /// user takes to drag a rectangle -- seconds, or forever if they wander
    /// off -- and that is not time to hold a thread the rest of the app
    /// shares.
    private static let queue = DispatchQueue(label: "com.cuonghm89.cnotch.screenshot", qos: .userInitiated)

    private var isCapturing = false
    /// The shot on offer in the notch right now, still in its temporary file.
    private(set) var pendingURL: URL?
    private var commitTask: Task<Void, Never>?

    /// Where a saved shot goes: the chosen folder, or the one the system uses
    /// when nothing is chosen, so the feature behaves sensibly before it is
    /// ever configured.
    static var destinationFolder: URL {
        if let path = Defaults[.quickScreenshotFolder], !path.isEmpty,
           let url = existingDirectory(path) {
            return url
        }
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           let url = existingDirectory(custom) {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private static func existingDirectory(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    // MARK: - Capturing

    func capture(_ mode: Mode) {
        guard Defaults[.quickScreenshotEnabled] else { return }
        // A second crosshair while the first is still up helps nobody, and a
        // shortcut is easy to lean on.
        guard !isCapturing else { return }
        // Starting a new shot answers the previous one: keep it, the same as
        // letting the strip time out.
        commitPending()
        isCapturing = true

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("CNotch-\(UUID().uuidString).png")

        Self.queue.async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = mode.arguments + [temporary.path]
            // terminationHandler, not waitUntilExit: nothing here may park a
            // thread waiting on a person.
            // Captured again at each step rather than reaching back into the
            // enclosing closure's `self`: referring to another closure's
            // capture from concurrent code is an error under Swift 6.
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isCapturing = false
                    // No file means the selection was cancelled, which is a
                    // normal thing to do and not worth a word.
                    guard FileManager.default.fileExists(atPath: temporary.path) else { return }
                    self?.offer(temporary)
                }
            }
            do {
                try process.run()
            } catch {
                AppLog.display.error("Could not start screencapture: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in self?.isCapturing = false }
            }
        }
    }

    private func offer(_ url: URL) {
        pendingURL = url
        guard Defaults[.screenshotQuickActionsEnabled], !CNotchViewCoordinator.shared.isScreenLocked else {
            // Nowhere to offer it, so treat it as the system would.
            commitPending()
            return
        }

        CNotchViewCoordinator.shared.toggleExpandingView(
            status: true,
            type: .pendingScreenshot,
            title: "Screenshot",
            subtitle: url.lastPathComponent,
            icon: "camera.viewfinder",
            url: url
        )

        // The strip hides itself after nine seconds; a moment later, whatever
        // is still pending is saved. Doing nothing means keeping it.
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.commitPending()
        }
    }

    // MARK: - Answers

    /// The image onto the pasteboard, and nothing onto the disk.
    func copyPending() {
        guard let url = pendingURL, let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        discardPending()
    }

    /// Moves the shot into the chosen folder.
    @discardableResult
    func savePending() -> URL? {
        guard let url = pendingURL else { return nil }
        pendingURL = nil
        commitTask?.cancel()
        commitTask = nil

        let folder = Self.destinationFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(Self.fileName())
        // Two shots inside the same second would otherwise collide.
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(Self.fileName(suffix: " (\(attempt))"))
            attempt += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            AppLog.display.error("Could not save the screenshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Saves first, then hands it to whichever app opens PNGs. Editing a file
    /// in the temporary folder would mean the editor saving into a place the
    /// system empties.
    func editPending() {
        guard let saved = savePending() else { return }
        NSWorkspace.shared.open(saved)
    }

    /// The timeout's answer, and the answer when a new shot replaces this one.
    private func commitPending() {
        guard pendingURL != nil else { return }
        savePending()
    }

    private func discardPending() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        commitTask?.cancel()
        commitTask = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Named the way the system names its own, so the two sort together when
    /// they share a folder.
    private static func fileName(suffix: String = "") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: Date()))\(suffix).png"
    }
}
