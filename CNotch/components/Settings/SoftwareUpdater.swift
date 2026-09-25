//
//  SoftwareUpdater.swift
//  CNotch
//
//  Created by Richard Kunkli on 09/08/2024.
//

import os
import Defaults
import SwiftUI
import Sparkle

@MainActor
final class SoftwareUpdateDelegate: NSObject, SPUUpdaterDelegate, ObservableObject {
    static let shared = SoftwareUpdateDelegate()

    /// An update that is downloaded, verified and staged, waiting only for
    /// the app to quit.
    struct PendingUpdate {
        let version: String
        /// Installs it and relaunches, with no further interaction.
        let installNow: () -> Void
    }

    @Published private(set) var pendingUpdate: PendingUpdate?

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Defaults[.softwareUpdateChannel] == .beta ? ["beta"] : []
    }

    /// Sparkle downloads an update, verifies it, unpacks it, and then waits
    /// in silence until the app quits. Nothing on screen says so.
    ///
    /// This copy of the app sat six releases behind for exactly that reason:
    /// the update was staged and ready the whole time, and the only way to
    /// discover it was to go looking in Sparkle's cache directory.
    ///
    /// Returning true takes over installing, which is what makes the
    /// "Relaunch now" button possible. The cost is that Sparkle stops its own
    /// update cycles while one is pending -- acceptable, because the reason
    /// it has those cycles is to eventually tell the user something, and that
    /// is now being done here, immediately and with a button.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            Self.shared.pendingUpdate = PendingUpdate(
                version: version,
                installNow: immediateInstallHandler
            )
            AppLog.display.notice("Update \(version, privacy: .public) staged, waiting for quit")
            Self.shared.announce(version)
        }
        return true
    }

    private func announce(_ version: String) {
        guard !CNotchViewCoordinator.shared.isScreenLocked else { return }
        CNotchViewCoordinator.shared.toggleExpandingView(
            status: true,
            type: .liveActivity,
            value: -1,
            title: "Update ready",
            subtitle: version,
            icon: "arrow.down.circle.fill"
        )
    }
}

/// CNotch has no Dock icon, so Sparkle's update window opens behind whatever
/// the user is actually looking at, with nothing to click in the Dock to find
/// it again. Sparkle warns about exactly this ("Background app automatically
/// schedules for update checks but does not implement gentle reminders"), and
/// it's why updates were being found but never installed: the alert was shown
/// and never seen.
extension SoftwareUpdateDelegate: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // A user-initiated check is already in focus. A scheduled one isn't,
        // so pull the app forward -- otherwise the window is effectively
        // invisible for a menu bar app.
        guard handleShowingUpdate, !state.userInitiated else { return }
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
        
        // Create our view model for our CheckForUpdatesView
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }
    
    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

struct UpdaterSettingsView: View {
    private let updater: SPUUpdater
    
    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool
    
    init(updater: SPUUpdater) {
        self.updater = updater
        self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }
    
    var body: some View {
        Section {
            Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }
            
            Toggle("Automatically download updates", isOn: $automaticallyDownloadsUpdates)
                .disabled(!automaticallyChecksForUpdates)
                .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                    updater.automaticallyDownloadsUpdates = newValue
                }
        } header: {
            HStack {
                Text("Software updates")
            }
        }
    }
}

private struct LiquidGlassChannelSegmentedPicker: View {
    @Binding var selection: SoftwareUpdateChannel

    @Namespace private var selectionNamespace
    @State private var hoveredItem: SoftwareUpdateChannel?

    private let selectionAnimation = Animation.spring(response: 0.32, dampingFraction: 0.82)

    var body: some View {
        HStack(spacing: 12) {
            Text("Release channel")
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(SoftwareUpdateChannel.allCases) { channel in
                    segment(for: channel)
                }
            }
            .padding(2)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
            .animation(selectionAnimation, value: selection)
        }
    }

    private func segment(for channel: SoftwareUpdateChannel) -> some View {
        let isSelected = selection == channel

        return Button {
            guard selection != channel else { return }
            withAnimation(selectionAnimation) {
                selection = channel
            }
        } label: {
            Text(LocalizedStringKey(channel.rawValue))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background {
                    if isSelected {
                        selectedSegmentBackground
                            .matchedGeometryEffect(id: "selectedChannelSegment", in: selectionNamespace)
                    } else if hoveredItem == channel {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredItem = isHovering ? channel : nil
            }
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var selectedSegmentBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.effectiveAccent)
    }
}

struct SoftwareUpdateChannelPicker: View {
    @Default(.softwareUpdateChannel) private var updateChannel

    var body: some View {
        LiquidGlassChannelSegmentedPicker(selection: $updateChannel)
    }
}
