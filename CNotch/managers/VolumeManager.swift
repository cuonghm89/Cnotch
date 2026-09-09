//
//  VolumeManager.swift
//  CNotch
//
//  Created by JeanLouis on 22/08/2025.
//

import AppKit
import Combine
import CoreAudio
import CoreBluetooth
import Defaults
import Foundation
import IOBluetooth
import ObjectiveC

final class VolumeManager: NSObject, ObservableObject {
    static let shared = VolumeManager()

    struct ConnectedBluetoothAccessory: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: String
        let batteryPercentage: Int?
    }

    struct OutputDevice: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
        let transportType: UInt32
        let uid: String
        let modelUID: String
        let iconURL: URL?
        let bluetoothBatteryPercentage: Int?

        var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE
        }

        var isBuiltIn: Bool {
            transportType == kAudioDeviceTransportTypeBuiltIn
        }

        var audioSourceIcon: String {
            if isBuiltIn {
                return "laptopcomputer"
            }
            if isBluetooth && bluetoothBatteryPercentage != nil {
                return "airpodspro"
            }

            switch transportType {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return "headphones"
            case kAudioDeviceTransportTypeAirPlay:
                return "airplayaudio"
            case kAudioDeviceTransportTypeUSB,
                 kAudioDeviceTransportTypeHDMI,
                 kAudioDeviceTransportTypeDisplayPort,
                 kAudioDeviceTransportTypeThunderbolt,
                 kAudioDeviceTransportTypeAggregate:
                return "hifispeaker.2"
            default:
                return "speaker.wave.2"
            }
        }

        var icon: String {
            if isBluetooth && bluetoothBatteryPercentage != nil {
                return "airpodspro"
            }

            switch transportType {
            case kAudioDeviceTransportTypeBuiltIn:
                return "airplayaudio"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return "headphones"
            case kAudioDeviceTransportTypeAirPlay:
                return "airplayaudio"
            case kAudioDeviceTransportTypeUSB,
                 kAudioDeviceTransportTypeHDMI,
                 kAudioDeviceTransportTypeDisplayPort,
                 kAudioDeviceTransportTypeThunderbolt,
                 kAudioDeviceTransportTypeAggregate:
                return "hifispeaker.2"
            default:
                return "speaker.wave.2"
            }
        }
    }

    @Published private(set) var rawVolume: Float = 0
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var lastChangeAt: Date = .distantPast
    @Published private(set) var currentOutputDevice: OutputDevice?
    private var knownBluetoothDeviceIDs: Set<AudioObjectID> = []
    private var knownBluetoothOutputAddresses: Set<String> = []
    private var isFirstDeviceDiscovery: Bool = true
    private var bluetoothConnectNotification: IOBluetoothUserNotification?

    /// Every currently-connected Bluetooth accessory (audio outputs from
    /// CoreAudio, plus keyboards/mice/trackpads/controllers from IOBluetooth),
    /// for the "connected devices" list in the expanded notch.
    @Published private(set) var connectedBluetoothAccessories: [ConnectedBluetoothAccessory] = []
    private var audioBluetoothAccessories: [ConnectedBluetoothAccessory] = []
    private var genericBluetoothAccessories: [String: ConnectedBluetoothAccessory] = [:]
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    let visibleDuration: TimeInterval = 1.2

    private var didInitialFetch = false
    private let step: Float32 = 1.0 / 16.0
    // Fallback software if hardware mute is not supported
    private var previousVolumeBeforeMute: Float32 = 0.2
    private var softwareMuted: Bool = false
    private var deviceVolumeListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var wakeObserver: Any?

    private override init() {
        super.init()
        setupSystemListeners()
        refreshOutputDevices()
        setupAudioListener()
        fetchCurrentVolume()

        // Non-audio Bluetooth accessories (keyboards, mice, trackpads...)
        // never appear in CoreAudio's device list, so they can't be caught
        // by the HAL property listener above -- register separately for
        // IOBluetooth's own connect notification, which fires for any device.
        bluetoothConnectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(handleBluetoothAccessoryConnected(_:device:))
        )
        // The connect notification above only fires for future connections,
        // so seed the list with accessories already connected at launch.
        if Defaults[.showBluetoothDeviceConnectionIndicator], CBManager.authorization == .allowedAlways {
            for device in BluetoothDeviceBridge.connectedDevices() {
                trackGenericAccessory(device)
            }
        }
        rebuildConnectedAccessoriesList()

        // CoreAudio's HAL property listeners can go silent across a sleep
        // cycle (the HAL daemon's IPC connection to this process can drop
        // without redelivering), with no "listener disabled" signal to
        // self-heal from -- unlike a CGEventTap, so re-register proactively.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setupSystemListeners()
            self?.refreshOutputDevices()
            self?.setupAudioListener()
            self?.fetchCurrentVolume()
        }
    }

    var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

    // MARK: - Public Control API
    @MainActor func increase(stepDivisor: Float = 1.0) {
        let divisor = max(stepDivisor, 0.25)
        let delta = step / Float32(divisor)
        let current = readVolumeInternal() ?? rawVolume
        let target = max(0, min(1, current + delta))
        setAbsolute(target)
        CNotchViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(target))
    }

    @MainActor func decrease(stepDivisor: Float = 1.0) {
        let divisor = max(stepDivisor, 0.25)
        let delta = step / Float32(divisor)
        let current = readVolumeInternal() ?? rawVolume
        let target = max(0, min(1, current - delta))
        setAbsolute(target)
        CNotchViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(target))
    }

    @MainActor func toggleMuteAction() {
        // Determine expected resulting state immediately and show HUD with that value
        let deviceID = systemOutputDeviceID()
        var willBeMuted = false
        var resultingVolume: Float32 = rawVolume

        if deviceID == kAudioObjectUnknown {
            willBeMuted = !softwareMuted
            resultingVolume = willBeMuted ? 0 : previousVolumeBeforeMute
        } else {
            let currentMuted = isMutedInternal()
            willBeMuted = !currentMuted
            resultingVolume = willBeMuted ? 0 : (readVolumeInternal() ?? rawVolume)
        }

        toggleMuteInternal()
        CNotchViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(willBeMuted ? 0 : resultingVolume))
    }
    
    func refresh() { fetchCurrentVolume() }

    func adjustRelative(delta: Float32) {
        if isMutedInternal() { toggleMuteInternal() }
        guard let current = readVolumeInternal() else {
            fetchCurrentVolume()
            return
        }
        let target = max(0, min(1, current + delta))
        writeVolumeInternal(target)  
        publish(volume: target, muted: isMutedInternal(), touchDate: true)
    }

    @MainActor func setAbsolute(_ value: Float32) {
        let clamped = max(0, min(1, value))
        let currentlyMuted = isMutedInternal()
        if currentlyMuted && clamped > 0 {
            toggleMuteInternal()
        }

        writeVolumeInternal(clamped)

        if clamped == 0 && !currentlyMuted {
            toggleMuteInternal()
        }

        publish(volume: clamped, muted: isMutedInternal(), touchDate: true)
    }

    // MARK: - CoreAudio Helpers
    private func systemOutputDeviceID() -> AudioObjectID {
        var defaultDeviceID = kAudioObjectUnknown
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &defaultDeviceID
        )
        if status != noErr { return kAudioObjectUnknown }
        return defaultDeviceID
    }

    func refreshOutputDevices() {
        let devices = outputDevices()
        let defaultDeviceID = systemOutputDeviceID()
        let previousKnown = knownBluetoothDeviceIDs
        var currentKnown: Set<AudioObjectID> = []
        var currentKnownAddresses: Set<String> = []
        var currentAudioAccessories: [ConnectedBluetoothAccessory] = []
        // Collect every device newly seen since the last refresh, not just
        // the last one in the loop -- a single callback can see more than
        // one Bluetooth device connect at once (e.g. two devices reconnect
        // together), and only the last would otherwise get a popup.
        var newlyConnected: [OutputDevice] = []

        for d in devices {
            if d.transportType == kAudioDeviceTransportTypeBluetooth || d.transportType == kAudioDeviceTransportTypeBluetoothLE {
                currentKnown.insert(d.id)
                currentKnownAddresses.insert(d.uid.filter(\.isHexDigit).lowercased())
                currentAudioAccessories.append(
                    ConnectedBluetoothAccessory(id: d.uid, name: d.name, icon: d.icon, batteryPercentage: d.bluetoothBatteryPercentage)
                )
                if !isFirstDeviceDiscovery && !previousKnown.contains(d.id) {
                    newlyConnected.append(d)
                }
            }
        }
        knownBluetoothDeviceIDs = currentKnown
        knownBluetoothOutputAddresses = currentKnownAddresses
        isFirstDeviceDiscovery = false

        DispatchQueue.main.async {
            self.currentOutputDevice = devices.first { $0.id == defaultDeviceID }
            self.audioBluetoothAccessories = currentAudioAccessories
            self.rebuildConnectedAccessoriesList()

            guard !newlyConnected.isEmpty,
                  Defaults[.showBluetoothDeviceConnectionIndicator],
                  CBManager.authorization == .allowedAlways
            else { return }
            self.announceBluetoothConnections(newlyConnected.map {
                BluetoothAnnouncement(name: $0.name, icon: $0.icon, batteryPercentage: $0.bluetoothBatteryPercentage)
            })
        }
    }

    struct BluetoothAnnouncement {
        let name: String
        let icon: String
        let batteryPercentage: Int?
    }

    private var bluetoothAnnouncementQueue: [BluetoothAnnouncement] = []
    private var bluetoothAnnouncementTask: Task<Void, Never>?

    /// Shows one "Connected" popup per device, in sequence -- the notch only
    /// has a single popup slot, so simultaneous connections queue instead of
    /// all but one being silently dropped. Audio-output devices (from
    /// CoreAudio) and other accessories like keyboards/mice/trackpads (from
    /// IOBluetooth) both funnel through here so they share one queue.
    private func announceBluetoothConnections(_ announcements: [BluetoothAnnouncement]) {
        bluetoothAnnouncementQueue.append(contentsOf: announcements)
        guard bluetoothAnnouncementTask == nil else { return }
        bluetoothAnnouncementTask = Task { @MainActor in
            while !bluetoothAnnouncementQueue.isEmpty {
                guard !Task.isCancelled else { return }
                let device = bluetoothAnnouncementQueue.removeFirst()
                CNotchViewCoordinator.shared.toggleExpandingView(
                    status: true,
                    type: .bluetoothDevice,
                    value: device.batteryPercentage.map { CGFloat($0) / 100 } ?? -1,
                    title: "Connected",
                    subtitle: device.name,
                    icon: device.icon
                )
                try? await Task.sleep(nanoseconds: 3_500_000_000)
            }
            bluetoothAnnouncementTask = nil
        }
    }

    /// Fires for ANY Bluetooth device connection -- audio or not -- so this
    /// is what actually catches keyboards, mice, trackpads, and controllers,
    /// which never show up in CoreAudio's device list.
    @objc private func handleBluetoothAccessoryConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async {
            guard Defaults[.showBluetoothDeviceConnectionIndicator],
                  CBManager.authorization == .allowedAlways,
                  let accessory = self.trackGenericAccessory(device)
            else { return }
            self.rebuildConnectedAccessoriesList()
            self.announceBluetoothConnections([
                BluetoothAnnouncement(name: accessory.name, icon: accessory.icon, batteryPercentage: accessory.batteryPercentage)
            ])
        }
    }

    @objc private func handleBluetoothAccessoryDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async {
            let address = (device.addressString ?? "").filter(\.isHexDigit).lowercased()
            guard !address.isEmpty else { return }
            self.genericBluetoothAccessories.removeValue(forKey: address)
            self.disconnectNotifications.removeValue(forKey: address)?.unregister()
            self.rebuildConnectedAccessoriesList()
        }
    }

    /// Records a non-audio accessory and registers for its disconnect so the
    /// "connected devices" list can drop it again later. Skips devices
    /// CoreAudio already tracks as an audio output, to avoid double-counting.
    @discardableResult
    private func trackGenericAccessory(_ device: IOBluetoothDevice) -> ConnectedBluetoothAccessory? {
        let address = (device.addressString ?? "").filter(\.isHexDigit).lowercased()
        guard !address.isEmpty, !knownBluetoothOutputAddresses.contains(address) else { return nil }
        let accessory = ConnectedBluetoothAccessory(
            id: address,
            name: device.name ?? device.addressString ?? "Bluetooth Device",
            icon: Self.accessoryIcon(for: device),
            batteryPercentage: BluetoothDeviceBridge.batteryPercentage(of: device)
        )
        genericBluetoothAccessories[address] = accessory
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(handleBluetoothAccessoryDisconnected(_:device:))
        )
        return accessory
    }

    private func rebuildConnectedAccessoriesList() {
        connectedBluetoothAccessories = audioBluetoothAccessories
            + genericBluetoothAccessories.values.sorted { $0.name < $1.name }
    }

    /// Bluetooth's own class-of-device bits -- major 0x05 is "Peripheral",
    /// and the minor field's top two bits split it into keyboard/pointing/
    /// combo, with joystick/gamepad called out separately.
    private static func accessoryIcon(for device: IOBluetoothDevice) -> String {
        // "bluetooth" isn't an SF Symbol (Apple doesn't ship the trademarked
        // logo as one) -- it silently renders nothing, so fall back to a
        // generic accessory glyph instead.
        guard device.deviceClassMajor == 0x05 else { return "cable.connector" }
        switch device.deviceClassMinor & 0x30 {
        case 0x10, 0x30: return "keyboard"
        case 0x20: return "computermouse"
        default: return (device.deviceClassMinor & 0x0F) == 0x02 ? "gamecontroller" : "cable.connector"
        }
    }

    private func outputDevices() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard isAliveOutputDevice(deviceID) else { return nil }
            let name = deviceName(deviceID) ?? "Output Device"
            let transportType = deviceTransportType(deviceID)
            let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
            return OutputDevice(
                id: deviceID,
                name: name,
                transportType: transportType,
                uid: uid,
                modelUID: stringProperty(deviceID, selector: kAudioDevicePropertyModelUID) ?? "",
                iconURL: deviceIconURL(deviceID),
                bluetoothBatteryPercentage: BluetoothDeviceBridge.batteryPercentage(
                    outputUID: uid,
                    isBluetooth: transportType == kAudioDeviceTransportTypeBluetooth
                        || transportType == kAudioDeviceTransportTypeBluetoothLE
                )
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isAliveOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &aliveAddress) else { return false }
        var alive: UInt32 = 0
        var aliveSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &aliveAddress, 0, nil, &aliveSize, &alive) == noErr,
              alive != 0
        else { return false }

        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
              streamsSize >= MemoryLayout<AudioBufferList>.size
        else { return false }

        let buffers = UnsafeMutableRawPointer.allocate(
            byteCount: Int(streamsSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffers.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &streamsSize, buffers) == noErr
        else { return false }
        return buffers.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers > 0
    }

    private func deviceName(_ deviceID: AudioObjectID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    private func stringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name) == noErr
        else { return nil }
        return name?.takeUnretainedValue() as String?
    }

    private func deviceIconURL(_ deviceID: AudioObjectID) -> URL? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIcon,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var iconURL: Unmanaged<CFURL>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFURL>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &iconURL) == noErr
        else { return nil }
        return iconURL?.takeRetainedValue() as URL?
    }

    private func deviceTransportType(_ deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transportType) == noErr
        else { return 0 }
        return transportType
    }

    private func setupSystemListeners() {
        removeSystemListeners()
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice)
        addSystemListener(kAudioHardwarePropertyDevices)
    }

    private func removeSystemListeners() {
        for (storedAddress, listener) in systemListeners {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, listener
            )
        }
        systemListeners.removeAll()
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshOutputDevices()
                self?.setupAudioListener()
                self?.fetchCurrentVolume()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, listener
        ) == noErr else { return }
        systemListeners.append((address, listener))
    }

    private func fetchCurrentVolume() {
        let deviceID = systemOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return }
        var volumes: [Float32] = []
        let candidateElements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2, 3, 4]
        for element in candidateElements {
            if let v = readValidatedScalar(deviceID: deviceID, element: element) {
                volumes.append(v)
            }
        }
        if !volumes.isEmpty {
            let avg = max(0, min(1, volumes.reduce(0, +) / Float32(volumes.count)))
            DispatchQueue.main.async {
                if self.rawVolume != avg {  
                    if self.didInitialFetch {
                        self.lastChangeAt = Date()
                    }
                }
                self.rawVolume = avg
                self.didInitialFetch = true

            }
        }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            var sizeNeeded: UInt32 = 0
            if AudioObjectGetPropertyDataSize(deviceID, &muteAddr, 0, nil, &sizeNeeded) == noErr,
                sizeNeeded == UInt32(MemoryLayout<UInt32>.size)
            {
                var muted: UInt32 = 0
                var mSize = sizeNeeded
                if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &mSize, &muted) == noErr
                {
                    let newMuted = muted != 0
                    DispatchQueue.main.async {
                        if self.isMuted != newMuted { self.lastChangeAt = Date() }
                        self.isMuted = newMuted
                    }
                }
            }
        }
    }

    private func setupAudioListener() {
        removeDeviceVolumeListeners()
        let deviceID = systemOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return }

        var masterAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &masterAddr) {
            addDeviceVolumeListener(deviceID, address: masterAddr)
        } else {
            for ch in [UInt32(1), UInt32(2)] {
                var chAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: ch
                )
                if AudioObjectHasProperty(deviceID, &chAddr) {
                    addDeviceVolumeListener(deviceID, address: chAddr)
                }
            }
        }

        // Mute
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            addDeviceVolumeListener(deviceID, address: muteAddr)
        }
    }

    private func addDeviceVolumeListener(_ deviceID: AudioObjectID, address: AudioObjectPropertyAddress) {
        var address = address
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.fetchCurrentVolume()
        }
        guard AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, listener) == noErr else { return }
        deviceVolumeListeners.append((deviceID, address, listener))
    }

    private func removeDeviceVolumeListeners() {
        for (deviceID, storedAddress, listener) in deviceVolumeListeners {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, listener)
        }
        deviceVolumeListeners.removeAll()
    }

    private func readVolumeInternal() -> Float32? {
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown { return nil }
        var collected: [Float32] = []
        for el in [kAudioObjectPropertyElementMain, 1, 2, 3, 4] {
            if let v = readValidatedScalar(deviceID: deviceID, element: el) { collected.append(v) }
        }
        guard !collected.isEmpty else { return nil }
        return collected.reduce(0, +) / Float32(collected.count)
    }

    private func writeVolumeInternal(_ value: Float32) {
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown { return }
        let newVal = max(0, min(1, value))

        var written = false
        if writeValidatedScalar(
            deviceID: deviceID, element: kAudioObjectPropertyElementMain, value: newVal)
        {
            written = true
        } else {
            var any = false
            for el in [UInt32](1...4) {
                if writeValidatedScalar(deviceID: deviceID, element: el, value: newVal) {
                    any = true
                }
            }
            written = any
        }
        if !written {
            // silent fail
        }
    }

    private func isMutedInternal() -> Bool {
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown { return softwareMuted }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return softwareMuted }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &muteAddr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<UInt32>.size)
        else { return softwareMuted }
        var muted: UInt32 = 0
        var size = sizeNeeded
        if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return softwareMuted
    }

    private func toggleMuteInternal() {
        let deviceID = systemOutputDeviceID()
        if deviceID == kAudioObjectUnknown {
            performSoftwareMuteToggle(currentVolume: rawVolume)
            return
        }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(deviceID, &muteAddr) {
            let currentVol = readVolumeInternal() ?? rawVolume
            performSoftwareMuteToggle(currentVolume: currentVol)
            return
        }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &muteAddr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<UInt32>.size)
        else {
            let currentVol = readVolumeInternal() ?? rawVolume
            performSoftwareMuteToggle(currentVolume: currentVol)
            return
        }
        var muted: UInt32 = 0
        var size = sizeNeeded
        if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted) == noErr {
            var newVal: UInt32 = muted == 0 ? 1 : 0
            AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, size, &newVal)
            let vol = readVolumeInternal() ?? rawVolume
            publish(volume: vol, muted: newVal != 0, touchDate: true)
        } else {
            let currentVol = readVolumeInternal() ?? rawVolume
            performSoftwareMuteToggle(currentVolume: currentVol)
        }
    }

    private func performSoftwareMuteToggle(currentVolume: Float32) {
        if softwareMuted {
            let restore = max(0, min(1, previousVolumeBeforeMute))
            writeVolumeInternal(restore)
            softwareMuted = false
            publish(volume: restore, muted: false, touchDate: true)
        } else {
            if currentVolume > 0.001 { previousVolumeBeforeMute = currentVolume }
            writeVolumeInternal(0)
            softwareMuted = true
            publish(volume: 0, muted: true, touchDate: true)
        }
    }

    private func readValidatedScalar(deviceID: AudioObjectID, element: UInt32) -> Float32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<Float32>.size)
        else { return nil }
        var vol = Float32(0)
        var size = sizeNeeded
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol)
        return status == noErr ? vol : nil
    }

    private func writeValidatedScalar(deviceID: AudioObjectID, element: UInt32, value: Float32)
        -> Bool
    {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }
        var sizeNeeded: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sizeNeeded) == noErr,
            sizeNeeded == UInt32(MemoryLayout<Float32>.size)
        else { return false }
        var val = value
        return AudioObjectSetPropertyData(deviceID, &addr, 0, nil, sizeNeeded, &val) == noErr
    }

    private func publish(volume: Float32, muted: Bool, touchDate: Bool) {
        DispatchQueue.main.async {
            if touchDate { self.lastChangeAt = Date() }
            self.rawVolume = volume
            self.isMuted = muted
        }
    }

}

extension Array where Element == Float32 {
    fileprivate var average: Float32? { isEmpty ? nil : reduce(0, +) / Float32(count) }
}

/// IOBluetoothDevice's battery accessors aren't in the public header, so
/// they still need selector-based reflection; everything else (the class
/// itself, `name`, `addressString`, `connectedDevices()`) is real linked
/// API now that IOBluetooth is imported directly.
private enum BluetoothDeviceBridge {
    static func batteryPercentage(outputUID: String, isBluetooth: Bool) -> Int? {
        guard UserDefaults.standard.bool(forKey: "onboardingCompleted"),
              Defaults[.showBluetoothDeviceConnectionIndicator],
              isBluetooth,
              !outputUID.isEmpty,
              let device = connectedDevices().first(where: { addressMatches(outputUID, $0) })
        else { return nil }
        return batteryPercentage(of: device)
    }

    static func batteryPercentage(of device: IOBluetoothDevice) -> Int? {
        if let single = batteryValue(device, selector: "batteryPercentSingle") {
            return single
        }
        let earbuds = [
            batteryValue(device, selector: "batteryPercentLeft"),
            batteryValue(device, selector: "batteryPercentRight")
        ].compactMap { $0 }
        return earbuds.min()
    }

    static func connectedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.perform(NSSelectorFromString("connectedDevices"))?
            .takeUnretainedValue() as? [IOBluetoothDevice]) ?? []
    }

    private static func addressMatches(_ outputUID: String, _ device: IOBluetoothDevice) -> Bool {
        guard let address = device.addressString else { return false }
        let normalizedAddress = address.filter(\.isHexDigit).lowercased()
        guard normalizedAddress.count == 12 else { return false }
        return outputUID.filter(\.isHexDigit).lowercased().contains(normalizedAddress)
    }

    private static func batteryValue(_ device: IOBluetoothDevice, selector name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard device.responds(to: selector), let implementation = device.method(for: selector) else { return nil }
        typealias BatterySelector = @convention(c) (AnyObject, Selector) -> Int32
        let send = unsafeBitCast(implementation, to: BatterySelector.self)
        let percentage = send(device, selector)
        return (0...100).contains(percentage) ? Int(percentage) : nil
    }
}
