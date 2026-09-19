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
import IOKit
import ObjectiveC

final class VolumeManager: NSObject, ObservableObject {
    static let shared = VolumeManager()

    struct ConnectedBluetoothAccessory: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: String
        let batteryPercentage: Int?
        /// True when `name` is a catalog key rather than a device's own name.
        /// A real device name must never be translated; the jack's label has
        /// to be, because the hardware supplies no name to show.
        var isLocalizedName: Bool = false
    }

    struct OutputDevice: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
        let transportType: UInt32
        let uid: String
        let modelUID: String
        let iconURL: URL?
        let bluetoothBatteryPercentage: Int?
        /// The 3.5mm jack. Built-in transport covers the speakers too, so the
        /// two are told apart by the output's data source rather than by its
        /// name, which is localized.
        let isHeadphoneJack: Bool

        var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE
        }

        var isBuiltIn: Bool {
            transportType == kAudioDeviceTransportTypeBuiltIn
        }

        var audioSourceIcon: String {
            // The 3.5mm jack reports built-in transport, so it has to be
            // checked first or headphones show as speakers.
            if isHeadphoneJack {
                return "headphones"
            }
            // A speaker, not a laptop. This icon is the button you press to
            // move the sound somewhere else, and nobody hunting for that
            // looks for a picture of a computer.
            if isBuiltIn {
                return "speaker.wave.2"
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
                 kAudioDeviceTransportTypeThunderbolt:
                return "hifispeaker.2"
            // Loopback drivers and the like -- BlackHole, a meeting app's
            // capture device. They are not speakers and showing them as one
            // makes the list impossible to read at a glance.
            case kAudioDeviceTransportTypeVirtual:
                return "waveform"
            // Several real devices wired together as one.
            case kAudioDeviceTransportTypeAggregate:
                return "square.stack.3d.up"
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
    /// Every output the system currently has. Already gathered on each
    /// refresh to work out which one is in use -- it was simply thrown away
    /// afterwards.
    @Published private(set) var availableOutputDevices: [OutputDevice] = []
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
    private var trackedBluetoothDevices: [String: IOBluetoothDevice] = [:]
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

    /// Makes `device` the system output.
    ///
    /// The notch already knew every device and which one was playing; tapping
    /// the name opened System Settings rather than doing anything with that.
    /// This is the one call that was missing.
    ///
    /// The list is refreshed straight afterwards rather than trusting the
    /// write: CoreAudio also posts a change notification, but a device can
    /// refuse to become the default -- one that has just disappeared, most
    /// obviously -- and the UI should show what is true, not what was asked
    /// for.
    @discardableResult
    func selectOutputDevice(_ device: OutputDevice) -> Bool {
        guard device.id != systemOutputDeviceID() else { return true }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = device.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &deviceID
        )
        refreshOutputDevices()
        return status == noErr
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
            } else if d.isHeadphoneJack {
                // Nothing identifies what is plugged into an analog jack --
                // it carries no data channel, so there is no name, brand or
                // model to read. What the Mac can tell is whether the plug
                // has a microphone contact, which separates headphones from
                // a headset.
                let hasMicrophone = externalMicrophoneConnected(among: devices)
                // Plugging into the jack is just as much "a device I
                // connected" as pairing over Bluetooth, and CoreAudio already
                // reports it -- it was only ever missing because the loop
                // looked at nothing but the Bluetooth transports.
                currentAudioAccessories.append(
                    ConnectedBluetoothAccessory(
                        id: d.uid,
                        name: hasMicrophone ? "Wired headset (3.5mm)" : "Wired headphones (3.5mm)",
                        icon: hasMicrophone ? "headset" : "headphones",
                        batteryPercentage: nil,
                        isLocalizedName: true
                    )
                )
            }
        }
        knownBluetoothDeviceIDs = currentKnown
        knownBluetoothOutputAddresses = currentKnownAddresses
        isFirstDeviceDiscovery = false
        // Warm the battery cache so the menu reads a filled one, but never
        // inline: this is reached from init() on the main thread as well as
        // from the HAL listener off it, and reload() waits on a subprocess.
        if !currentAudioAccessories.isEmpty {
            DispatchQueue.global(qos: .utility).async { BluetoothBatteryLevels.reload() }
        }

        DispatchQueue.main.async {
            self.availableOutputDevices = devices
            self.currentOutputDevice = devices.first { $0.id == defaultDeviceID }
            self.audioBluetoothAccessories = currentAudioAccessories
            self.rebuildConnectedAccessoriesList()

            guard !newlyConnected.isEmpty,
                  Defaults[.showBluetoothDeviceConnectionIndicator],
                  CBManager.authorization == .allowedAlways
            else { return }
            self.announceDeviceConnections(newlyConnected.map {
                DeviceAnnouncement(name: $0.name, icon: $0.icon, batteryPercentage: $0.bluetoothBatteryPercentage)
            })
        }
    }

    struct DeviceAnnouncement {
        let title: String
        let name: String
        let icon: String
        let batteryPercentage: Int?

        init(title: String = "Connected", name: String, icon: String, batteryPercentage: Int?) {
            self.title = title
            self.name = name
            self.icon = icon
            self.batteryPercentage = batteryPercentage
        }
    }

    private var bluetoothAnnouncementQueue: [DeviceAnnouncement] = []
    private var bluetoothAnnouncementTask: Task<Void, Never>?

    /// Shows one "Connected" popup per device, in sequence -- the notch only
    /// has a single popup slot, so simultaneous connections queue instead of
    /// all but one being silently dropped. Audio-output devices (from
    /// CoreAudio) and other accessories like keyboards/mice/trackpads (from
    /// IOBluetooth) and USB devices (from IOKit) all funnel through here so
    /// they share one queue.
    func announceDeviceConnections(_ announcements: [DeviceAnnouncement]) {
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
                    title: device.title,
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
            self.announceDeviceConnections([
                DeviceAnnouncement(
                    name: accessory.name,
                    icon: accessory.icon,
                    batteryPercentage: Self.batteryPercentage(for: accessory)
                )
            ])
        }
    }

    @objc private func handleBluetoothAccessoryDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async {
            let address = (device.addressString ?? "").filter(\.isHexDigit).lowercased()
            guard !address.isEmpty else { return }
            self.forgetGenericAccessory(address)
            self.rebuildConnectedAccessoriesList()
        }
    }

    /// Records a non-audio accessory and registers for its disconnect so the
    /// "connected devices" list can drop it again later. Skips devices
    /// CoreAudio already tracks as an audio output, to avoid double-counting.
    @discardableResult
    private func trackGenericAccessory(_ device: IOBluetoothDevice) -> ConnectedBluetoothAccessory? {
        let address = (device.addressString ?? "").filter(\.isHexDigit).lowercased()
        // `connectedDevices()` answers from the Bluetooth stack's cached
        // device list, which keeps listing a device that has since dropped
        // its link -- a keyboard switched over to its USB cable, say. Ask
        // the device itself instead; that's a live query.
        guard device.isConnected() else { return nil }
        // Every connected device, whatever its class. This used to keep only
        // "Peripheral" (0x05) because anything else showed a bogus 0%, but
        // that was the battery read being wrong, not the device being the
        // wrong kind -- and it silently dropped headsets, which are class
        // 0x04. Deduplication against CoreAudio happens when the list is
        // built, not here: a Bluetooth headset appears in CoreAudio only
        // while it is the active audio route and vanishes from it otherwise,
        // so the entry has to exist to fall back on.
        guard !address.isEmpty else { return nil }
        let accessory = ConnectedBluetoothAccessory(
            id: address,
            name: device.name ?? device.addressString ?? "Bluetooth Device",
            icon: Self.accessoryIcon(for: device),
            batteryPercentage: BluetoothDeviceBridge.batteryPercentage(of: device)
        )
        genericBluetoothAccessories[address] = accessory
        trackedBluetoothDevices[address] = device
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(handleBluetoothAccessoryDisconnected(_:device:))
        )
        return accessory
    }

    private func forgetGenericAccessory(_ address: String) {
        genericBluetoothAccessories.removeValue(forKey: address)
        trackedBluetoothDevices.removeValue(forKey: address)
        disconnectNotifications.removeValue(forKey: address)?.unregister()
    }

    /// Current battery for an accessory: the live HID reading when there is
    /// one, otherwise whatever was captured for it (audio devices get theirs
    /// refreshed by the CoreAudio path instead).
    static func batteryPercentage(for accessory: ConnectedBluetoothAccessory) -> Int? {
        // An accessory's id is a bare address when it came from IOBluetooth
        // but a CoreAudio UID -- "78-5E-A2-E3-E9-FA:output" -- when it came
        // from the audio side, while both battery sources are keyed by plain
        // address. Without normalising, every audio device silently missed.
        let address = normalizedAddress(accessory.id)
        return HIDBatteryLevels.percentage(forAddress: address)
            ?? BluetoothBatteryLevels.percentage(forName: accessory.name)
            ?? accessory.batteryPercentage
    }

    private static func normalizedAddress(_ identifier: String) -> String {
        let hex = identifier.filter(\.isHexDigit).lowercased()
        // A UID can carry hex letters beyond the address itself, so keep the
        // six bytes an address actually is.
        return hex.count > 12 ? String(hex.prefix(12)) : hex
    }

    /// Republish the list so a battery that arrived after the view was last
    /// built shows up.
    func refreshConnectedAccessories() {
        rebuildConnectedAccessoriesList()
    }

    private func rebuildConnectedAccessoriesList() {
        // A disconnect notification can go missing (device out of range, the
        // Bluetooth stack restarting across a sleep cycle), which otherwise
        // leaves the accessory listed as connected forever.
        for (address, device) in trackedBluetoothDevices where !device.isConnected() {
            forgetGenericAccessory(address)
        }
        // CoreAudio and IOBluetooth can both know the same headset; prefer
        // CoreAudio's entry, which carries the audio-side battery reading.
        let audioAddresses = Set(audioBluetoothAccessories.map { $0.id.filter(\.isHexDigit).lowercased() })
        connectedBluetoothAccessories = audioBluetoothAccessories
            + genericBluetoothAccessories.values
                .filter { !audioAddresses.contains($0.id) }
                .sorted { $0.name < $1.name }
    }

    /// Bluetooth's own class-of-device bits -- major 0x05 is "Peripheral",
    /// and the minor field's top two bits split it into keyboard/pointing/
    /// combo, with joystick/gamepad called out separately.
    private static func accessoryIcon(for device: IOBluetoothDevice) -> String {
        // "bluetooth" isn't an SF Symbol (Apple doesn't ship the trademarked
        // logo as one) -- it silently renders nothing, so every branch has to
        // end at some other glyph.
        switch device.deviceClassMajor {
        case 0x01: return "laptopcomputer"
        case 0x02: return "iphone"
        case 0x04:
            // Audio/Video. Minor 0x05 is a loudspeaker; the rest of what a
            // Mac ever pairs with here is worn on the head.
            return (device.deviceClassMinor & 0x3F) == 0x05 ? "hifispeaker" : "headphones"
        case 0x05:
            switch device.deviceClassMinor & 0x30 {
            case 0x10, 0x30: return "keyboard"
            case 0x20: return "computermouse"
            default: return (device.deviceClassMinor & 0x0F) == 0x02 ? "gamecontroller" : "cable.connector"
            }
        case 0x06: return "printer"
        case 0x07: return "applewatch"
        default: return "cable.connector"
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
                ),
                isHeadphoneJack: transportType == kAudioDeviceTransportTypeBuiltIn
                    && isHeadphoneJack(deviceID)
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

    /// A headset plugged into the same jack shows up as a second, input-side
    /// built-in device whose source is 'emic' -- the built-in microphone
    /// reports 'imic' instead.
    private func externalMicrophoneConnected(among devices: [OutputDevice]) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return false }
        var deviceIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return false }

        return deviceIDs.contains { deviceID in
            var source = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(deviceID, &source) else { return false }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(deviceID, &source, 0, nil, &size, &value) == noErr
            else { return false }
            return value == 0x656D_6963  // 'emic'
        }
    }

    /// CoreAudio reports the built-in output's data source as a four-char
    /// code: 'hdpn' when something is plugged into the headphone jack, 'ispk'
    /// for the internal speakers.
    private func isHeadphoneJack(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var source: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &source) == noErr
        else { return false }
        return source == 0x6864_706E  // 'hdpn'
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

/// Battery level for HID accessories -- trackpads, keyboards, mice -- lives on
/// their IOKit HID service as `BatteryPercent`, keyed by the Bluetooth address.
/// `IOBluetoothDevice`'s private `batteryPercent*` selectors only answer for
/// audio devices like AirPods, which is why a Magic Trackpad reporting 23% in
/// `ioreg` showed no battery at all in the notch.
///
/// Read on demand rather than stored: the level is otherwise frozen at whatever
/// it was the moment the device connected, and never recovers if that first
/// read came back empty. Cached briefly so repeated SwiftUI body evaluations
/// don't each walk the registry.
enum HIDBatteryLevels {
    private static var cache: [String: Int] = [:]
    private static var cachedAt = Date.distantPast

    static func percentage(forAddress address: String) -> Int? {
        if Date().timeIntervalSince(cachedAt) > 5 {
            reload()
        }
        return cache[address]
    }

    private static func reload() {
        cachedAt = Date()
        var levels: [String: Int] = [:]
        defer { cache = levels }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let address = IORegistryEntryCreateCFProperty(
                    service, "DeviceAddress" as CFString, kCFAllocatorDefault, 0
                  )?.takeRetainedValue() as? String,
                  let percentage = IORegistryEntryCreateCFProperty(
                    service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0
                  )?.takeRetainedValue() as? Int
            else { continue }
            levels[address.filter(\.isHexDigit).lowercased()] = percentage
        }
    }
}

/// Battery for a Bluetooth audio device that the private `IOBluetoothDevice`
/// selectors stay silent about. They answer for AirPods and not much else --
/// a JBL LIVE460NC reports nothing through them while macOS itself knows the
/// level perfectly well, and `system_profiler` is the one place that exposes
/// what the Bluetooth daemon holds without private API.
///
/// Reloaded from the CoreAudio refresh, which already runs off the main
/// thread, so opening the menu reads a warm cache rather than waiting ~100ms
/// for a subprocess.
enum BluetoothBatteryLevels {
    private static let lock = NSLock()
    private static var cache: [String: Int] = [:]
    private static var cachedAt = Date.distantPast
    private static var isReloading = false

    /// A pure cache read, and it has to stay that way: this is called from
    /// inside a SwiftUI body, and reloading runs a subprocess. Waiting on one
    /// during a render pumps the run loop, re-enters SwiftUI's update, and
    /// AttributeGraph aborts the process -- which is how this crashed once
    /// already. A stale cache schedules a refresh rather than waiting for one,
    /// and the refresh republishes the list so the number arrives a moment
    /// later.
    static func percentage(forName name: String) -> Int? {
        let key = normalizedName(name)
        lock.lock()
        let value = cache[key]
        let shouldRefresh = !isReloading && Date().timeIntervalSince(cachedAt) > 60
        if shouldRefresh { isReloading = true }
        lock.unlock()

        if shouldRefresh {
            DispatchQueue.global(qos: .utility).async {
                reload()
                lock.lock()
                isReloading = false
                lock.unlock()
                DispatchQueue.main.async {
                    VolumeManager.shared.refreshConnectedAccessories()
                }
            }
        }
        return value
    }

    /// `pmset -g accps` lists exactly what the Bluetooth daemon knows, for
    /// every accessory at once, in about 10ms.
    ///
    /// `system_profiler` was the obvious place to look and turned out to be
    /// the wrong one: it reported the JBL at 100% one afternoon and no battery
    /// at all an hour later, while the daemon had a figure the whole time. It
    /// is also ten times slower.
    ///
    /// Matched on the name rather than the address because that is all this
    /// output carries -- normalised, since pmset mangles a curly apostrophe
    /// into a lone surrogate and "Cuong Hoang's Trackpad" would never compare
    /// equal to itself otherwise.
    static func reload() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Stamp the attempt whatever happens. Leaving cachedAt alone on
        // failure kept the cache eternally stale, and since every finished
        // attempt republishes the list, the re-render scheduled another
        // attempt -- a spawn/publish loop for as long as the failure lasted.
        defer {
            lock.lock()
            cachedAt = Date()
            lock.unlock()
        }
        guard (try? process.run()) != nil,
              let data = try? pipe.fileHandleForReading.readToEnd()
        else { return }
        process.waitUntilExit()

        // Not String(data:encoding:.utf8): pmset mangles a curly apostrophe
        // into a byte sequence that isn't valid UTF-8, so that initialiser
        // returns nil and the whole read silently yields nothing. Decoding
        // leniently substitutes a replacement character instead, which the
        // name normalisation then drops anyway.
        let output = String(decoding: data, as: UTF8.self)

        var levels: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            // "-JBL LIVE460NC (id=25760649)\t90%; discharging present: true"
            guard let idRange = line.range(of: " (id=") else { continue }
            let name = line[line.startIndex..<idRange.lowerBound]
                .drop { $0 == " " || $0 == "-" }
            // Both markers are searched after the id, never across the whole
            // line: a device named "Bose 100%" would otherwise put the "%"
            // before the ")", and the resulting inverted Range traps.
            guard let closing = line.range(of: ")", range: idRange.upperBound..<line.endIndex),
                  let percentRange = line.range(of: "%", range: closing.upperBound..<line.endIndex),
                  let percentage = Int(line[closing.upperBound..<percentRange.lowerBound]
                    .filter(\.isNumber))
            else { continue }
            levels[normalizedName(String(name))] = percentage
        }

        lock.lock()
        cache = levels
        cachedAt = Date()
        lock.unlock()
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
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
        // 0 is what this selector answers with for a device that simply
        // has no battery to report (a phone, a Mac) -- not an empty battery.
        return (1...100).contains(percentage) ? Int(percentage) : nil
    }
}
