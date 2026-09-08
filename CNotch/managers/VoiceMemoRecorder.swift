//
//  VoiceMemoRecorder.swift
//  CNotch
//
//  Quick voice memo capture, saved straight into the Shelf.
//

import AVFoundation
import AppKit

@MainActor
final class VoiceMemoRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = VoiceMemoRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: Int = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    private var recordingFailed = false

    func toggle() {
        if isRecording {
            stop()
        } else {
            requestAccessAndStart()
        }
    }

    private func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in if granted { self.start() } }
            }
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func start() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMemo-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder.delegate = self
        guard recorder.record() else { return }

        self.recorder = recorder
        recordingURL = url
        recordingFailed = false
        isRecording = true
        elapsedSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsedSeconds += 1 }
        }
    }

    private func stop() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false

        guard let tempURL = recordingURL else { return }
        recordingURL = nil

        // A mid-recording mic loss (unplugged, access revoked, seized by
        // another app) doesn't stop the countdown or flip isRecording on its
        // own -- only the delegate callbacks below notice it. Skip saving a
        // failed or empty (zero/near-zero byte) recording instead of adding
        // a silently-corrupt item to the Shelf.
        let attributes = try? FileManager.default.attributesOfItem(atPath: tempURL.path)
        let fileSize = attributes?[.size] as? Int
        guard !recordingFailed, let fileSize, fileSize > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        saveToShelf(tempURL)
    }

    private func saveToShelf(_ tempURL: URL) {
        let name = "Voice Memo \(Self.timestampFormatter.string(from: Date())).m4a"
        let renamed = tempURL.deletingLastPathComponent().appendingPathComponent(name)
        (try? FileManager.default.moveItem(at: tempURL, to: renamed)).map { _ in }

        let sourceURL = FileManager.default.fileExists(atPath: renamed.path) ? renamed : tempURL
        guard let shelfURL = TemporaryFileStorageService.shared.copyToShelfStorage(from: sourceURL) else { return }
        try? FileManager.default.removeItem(at: sourceURL)

        guard let bookmark = try? Bookmark(url: shelfURL) else { return }
        ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)])
    }

    // MARK: - AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Task { @MainActor in self.recordingFailed = true }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.recordingFailed = true
            // The recorder just told us it can no longer encode -- stop
            // immediately rather than let the countdown keep running against
            // a recording that's already dead.
            if self.isRecording { self.stop() }
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}
