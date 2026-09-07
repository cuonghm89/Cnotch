//
//  PomodoroManager.swift
//  CNotch
//

import AppKit
import UserNotifications

@MainActor
final class PomodoroManager: NSObject, ObservableObject {
    static let shared = PomodoroManager()

    @Published private(set) var isRunning = false
    @Published private(set) var remainingSeconds: Int = 0
    private(set) var totalSeconds: Int = 0

    private var timer: Timer?

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1 - (Double(remainingSeconds) / Double(totalSeconds))
    }

    var remainingText: String {
        String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    func start(minutes: Int) {
        guard minutes > 0 else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        timer?.invalidate()
        totalSeconds = minutes * 60
        remainingSeconds = totalSeconds
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        remainingSeconds = 0
        totalSeconds = 0
    }

    private func tick() {
        guard remainingSeconds > 1 else {
            remainingSeconds = 0
            notifyDone()
            cancel()
            return
        }
        remainingSeconds -= 1
    }

    private func notifyDone() {
        let content = UNMutableNotificationContent()
        content.title = "Pomodoro finished"
        content.body = "Time's up — take a break!"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
