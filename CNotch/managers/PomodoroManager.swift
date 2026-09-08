//
//  PomodoroManager.swift
//  CNotch
//

import AppKit
import Defaults
import UserNotifications

@MainActor
final class PomodoroManager: NSObject, ObservableObject {
    static let shared = PomodoroManager()

    @Published private(set) var isRunning = false
    @Published private(set) var remainingSeconds: Int = 0
    private(set) var totalSeconds: Int = 0

    private var timer: Timer?
    private var deadline: Date?

    override init() {
        super.init()
        restoreIfNeeded()
    }

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
        begin(deadline: Date().addingTimeInterval(TimeInterval(minutes * 60)), totalSeconds: minutes * 60)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        isRunning = false
        remainingSeconds = 0
        totalSeconds = 0
        Defaults[.pomodoroDeadline] = nil
        Defaults[.pomodoroTotalSeconds] = 0
    }

    /// (Re)starts the countdown against a fixed wall-clock deadline instead
    /// of decrementing a counter once a second -- a decrementing counter
    /// silently pauses for the entire duration of a sleep (the repeating
    /// Timer just doesn't fire while asleep) instead of reflecting real
    /// elapsed time, and has no way to be restored after a relaunch.
    private func begin(deadline: Date, totalSeconds: Int) {
        timer?.invalidate()
        self.deadline = deadline
        self.totalSeconds = totalSeconds
        isRunning = true
        Defaults[.pomodoroDeadline] = deadline
        Defaults[.pomodoroTotalSeconds] = totalSeconds
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    private func restoreIfNeeded() {
        guard let savedDeadline = Defaults[.pomodoroDeadline], Defaults[.pomodoroTotalSeconds] > 0 else { return }
        guard savedDeadline > Date() else {
            Defaults[.pomodoroDeadline] = nil
            Defaults[.pomodoroTotalSeconds] = 0
            return
        }
        begin(deadline: savedDeadline, totalSeconds: Defaults[.pomodoroTotalSeconds])
    }

    private func tick() {
        guard let deadline else {
            cancel()
            return
        }
        let remaining = Int(deadline.timeIntervalSinceNow.rounded(.up))
        guard remaining > 0 else {
            remainingSeconds = 0
            notifyDone()
            cancel()
            return
        }
        remainingSeconds = remaining
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
