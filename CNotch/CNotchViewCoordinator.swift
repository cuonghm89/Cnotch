//
//  CNotchViewCoordinator.swift
//  CNotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
    case bluetoothDevice
    case liveActivity
    case screenshot
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

/// Wire format for third-party apps pushing a live activity onto the notch.
/// `value` is an optional 0...1 progress fraction; omit it for activities
/// with no progress to report.
struct ExternalLiveActivityPayload: Codable {
    var show: Bool
    var title: String
    var subtitle: String?
    var icon: String?
    var value: Double?
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
    var title: String = ""
    var subtitle: String = ""
    var icon: String = "airpodspro"
    var url: URL?
}

@MainActor
class CNotchViewCoordinator: ObservableObject {
    static let shared = CNotchViewCoordinator()

    @Published var currentView: FeatureModuleID = .home {
        didSet {
            let modules = FeatureModuleRegistry.shared
            guard modules.isAvailable(currentView) else {
                currentView = .home
                return
            }

            if oldValue == .camera, currentView != .camera {
                modules.deactivate(.camera)
            }
            modules.activate(currentView)
        }
    }
    @Published var helloAnimationRunning: Bool = false
    /// Screen-lock state, shared so features that expose personal data
    /// (Clipboard, Shelf, Calendar, Camera, Quick Note, Voice Memo,
    /// Screenshot Quick Actions) can restrict themselves while locked --
    /// anyone at a locked Mac shouldn't be able to browse or use them
    /// without actually signing in.
    @Published var isScreenLocked: Bool = false {
        didSet {
            guard isScreenLocked, !oldValue, currentView != .home else { return }
            currentView = .home
        }
    }
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            } else {
                currentView = .home
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if Defaults[.hudReplacement] && authorized {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                } else {
                    MediaKeyInterceptor.shared.stop()
                }
            }
        }
        XPCHelperClient.shared.startMonitoringAccessibilityAuthorization()

        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .dropFirst()
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(
                                promptIfNeeded: UserDefaults.standard.bool(forKey: "onboardingCompleted")
                            )
                            if Task.isCancelled { return }

                            if granted {
                                await MediaKeyInterceptor.shared.start()
                            } else {
                                Defaults[.hudReplacement] = false
                                MediaKeyInterceptor.shared.stop()
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            if Defaults[.hudReplacement] {
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if !authorized {
                    Defaults[.hudReplacement] = false
                    MediaKeyInterceptor.shared.stop()
                } else {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }

        setupExternalLiveActivityObserver()

        if Defaults[.weatherEnabled] {
            WeatherManager.shared.start()
        }
        weatherEnabledCancellable = Defaults.publisher(.weatherEnabled)
            .dropFirst()
            .sink { change in
                if change.newValue {
                    WeatherManager.shared.start()
                } else {
                    WeatherManager.shared.stop()
                }
            }

        if Defaults[.screenshotQuickActionsEnabled] {
            ScreenshotWatcher.shared.start()
        }
        screenshotQuickActionsCancellable = Defaults.publisher(.screenshotQuickActionsEnabled)
            .dropFirst()
            .sink { change in
                if change.newValue {
                    ScreenshotWatcher.shared.start()
                } else {
                    ScreenshotWatcher.shared.stop()
                }
            }

        if Defaults[.systemStatsEnabled] {
            SystemStatsManager.shared.start()
        }
        systemStatsCancellable = Defaults.publisher(.systemStatsEnabled)
            .dropFirst()
            .sink { change in
                if change.newValue {
                    SystemStatsManager.shared.start()
                } else {
                    SystemStatsManager.shared.stop()
                }
            }
    }

    private var weatherEnabledCancellable: AnyCancellable?
    private var screenshotQuickActionsCancellable: AnyCancellable?
    private var systemStatsCancellable: AnyCancellable?

    // MARK: - Third-Party Live Activities
    //
    // Any local process can push a live activity onto the notch by posting a
    // distributed notification named `externalLiveActivityNotificationName`
    // with a JSON-encoded `ExternalLiveActivityPayload` under the
    // "payload" key in its userInfo. Example from the command line:
    //
    //   osascript -l JavaScript -e '
    //     ObjC.import("Foundation")
    //     const json = JSON.stringify({title: "Building…", subtitle: "42%", icon: "hammer.fill", value: 0.42})
    //     $.NSDistributedNotificationCenter.defaultCenter
    //       .postNotificationNameObjectUserInfo("com.cuonghm89.cnotch.liveActivity", "", $({payload: json}))'
    //
    private func setupExternalLiveActivityObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.externalLiveActivityNotificationName,
            object: nil,
            queue: .main
        ) { notification in
            guard let json = notification.userInfo?["payload"] as? String,
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ExternalLiveActivityPayload.self, from: data)
            else { return }

            Task { @MainActor in
                guard Defaults[.externalLiveActivitiesEnabled] else { return }

                CNotchViewCoordinator.shared.toggleExpandingView(
                    status: payload.show,
                    type: .liveActivity,
                    value: CGFloat(min(max(payload.value ?? -1, -1), 1)),
                    title: payload.title,
                    subtitle: payload.subtitle ?? "",
                    icon: payload.icon ?? "app.badge"
                )
            }
        }
    }

    static let externalLiveActivityNotificationName = Notification.Name("com.cuonghm89.cnotch.liveActivity")

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = ""
    ) {
        sneakPeekDuration = type == .music ? Defaults[.sneakPeekDuration] : duration
        if type != .music {
            if !Defaults[.hudReplacement] {
                return
            }
        }
        withAnimation(.smooth) {
            sneakPeek = .init(show: status, type: type, value: value, icon: icon)
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            self.toggleSneakPeek(status: false, type: .music)
        }
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium,
        title: String = "",
        subtitle: String = "",
        icon: String = "airpodspro",
        url: URL? = nil
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
                self.expandingView.title = title
                self.expandingView.subtitle = subtitle
                self.expandingView.icon = icon
                self.expandingView.url = url
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : expandingView.type == .screenshot ? 6 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }
}
