//
//  CNotchHeader.swift
//  CNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct CNotchHeader: View {
    @EnvironmentObject var vm: CNotchViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = CNotchViewCoordinator.shared
    @ObservedObject private var clipboardHistory = ClipboardHistoryStore.shared
    @ObservedObject private var modules = FeatureModuleRegistry.shared
    @ObservedObject private var weather = WeatherManager.shared
    @ObservedObject private var systemStats = SystemStatsManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: NotchMotionPolicy {
        .init(reduceMotion: reduceMotion)
    }

    var body: some View {
        let tabCount = CGFloat(modules.installedModules.count)
        let tabContentWidth = tabCount * moduleTabWidth

        ZStack {
            Rectangle()
                .fill(notchBackgroundColor)
                .frame(width: vm.closedNotchSize.width)
                .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 0) {
                TabSelectionView(tabWidth: moduleTabWidth)
                    .frame(width: tabContentWidth, alignment: .leading)
                    .padding(.leading, moduleTabLeadingPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .notchHeaderVisibility(vm.notchState != .closed)

                Color.clear
                    .frame(width: vm.closedNotchSize.width)

                HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(motion.hudTransition)
                            .animation(motion.hudAnimation, value: coordinator.sneakPeek.show)
                    } else {
                        if coordinator.currentView == .clipboard {
                            Button(role: .destructive) {
                                clipboardHistory.clear()
                            } label: {
                                Label("Clear", systemImage: "trash")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .disabled(clipboardHistory.entries.isEmpty)
                        }
                        if Defaults[.weatherEnabled], let celsius = weather.temperatureCelsius {
                            HStack(spacing: 3) {
                                Image(systemName: weather.symbolName)
                                Text("\(Int(celsius.rounded()))°")
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                        if Defaults[.systemStatsEnabled] {
                            HStack(spacing: 3) {
                                Image(systemName: "cpu")
                                Text("\(Int((systemStats.cpuUsage * 100).rounded()))%")
                                Image(systemName: "memorychip")
                                Text("\(Int((systemStats.memoryUsage * 100).rounded()))%")
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        if Defaults[.quickNoteEnabled] {
                            QuickNoteButton()
                        }
                        if Defaults[.pomodoroButtonEnabled] {
                            PomodoroButton()
                        }
                        if Defaults[.voiceMemoButtonEnabled] {
                            VoiceMemoButton()
                        }
                        if Defaults[.settingsIconInNotch] {
                            HoverButton(
                                icon: "gear",
                                iconColor: .white,
                                showsHoverHighlight: false,
                                accessibilityLabel: "Open settings",
                                action: SettingsWindowController.present
                            )
                        }
                        if Defaults[.batteryFeatureEnabled] && Defaults[.showBatteryIndicator] {
                            CNotchBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                        }
                    }
                    }
                }
                .font(.system(.headline, design: .rounded))
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .notchHeaderVisibility(vm.notchState != .closed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: openNotchHeaderHeight)
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    private var notchBackgroundColor: Color {
        NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0
            ? .black : .clear
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

private extension View {
    func notchHeaderVisibility(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .blur(radius: isVisible ? 0 : 20)
            .zIndex(2)
    }
}

#Preview {
    CNotchHeader().environmentObject(CNotchViewModel())
}
