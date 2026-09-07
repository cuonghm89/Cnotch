//
//  MicrophoneManager.swift
//  CNotch
//

import AppKit
import CoreAudio

/// Reads and toggles the default input device's mute state, with a software
/// fallback (dropping input volume to 0) for devices that don't expose a
/// hardware mute property -- mirrors VolumeManager's output-mute handling.
final class MicrophoneManager: NSObject, ObservableObject {
    static let shared = MicrophoneManager()

    @Published private(set) var isMuted: Bool = false

    private var previousVolumeBeforeMute: Float32 = 1.0
    private var softwareMuted = false
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var defaultDeviceListener: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?

    private override init() {
        super.init()
        setupDefaultDeviceListener()
        setupMuteListener()
        refresh()
    }

    func refresh() {
        isMuted = readMuted() ?? softwareMuted
    }

    @MainActor func toggleMute() {
        let deviceID = systemInputDeviceID()
        guard deviceID != kAudioObjectUnknown else {
            performSoftwareMuteToggle()
            return
        }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else {
            performSoftwareMuteToggle()
            return
        }

        var newVal: UInt32 = isMuted ? 0 : 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, size, &newVal) == noErr else {
            performSoftwareMuteToggle()
            return
        }

        publish(muted: newVal != 0)
    }

    // MARK: - CoreAudio helpers

    private func systemInputDeviceID() -> AudioObjectID {
        var deviceID = kAudioObjectUnknown
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    private func readMuted() -> Bool? {
        let deviceID = systemInputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return nil }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    private func readVolume() -> Float32? {
        let deviceID = systemInputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol) == noErr else { return nil }
        return vol
    }

    private func writeVolume(_ value: Float32) {
        let deviceID = systemInputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return }
        var val = max(0, min(1, value))
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &val)
    }

    private func performSoftwareMuteToggle() {
        if softwareMuted {
            writeVolume(max(0.1, previousVolumeBeforeMute))
            softwareMuted = false
            publish(muted: false)
        } else {
            previousVolumeBeforeMute = readVolume() ?? 1.0
            writeVolume(0)
            softwareMuted = true
            publish(muted: true)
        }
    }

    private func publish(muted: Bool) {
        DispatchQueue.main.async {
            self.isMuted = muted
            CNotchViewCoordinator.shared.toggleSneakPeek(
                status: true,
                type: .mic,
                duration: 1.5,
                value: muted ? 0 : 1
            )
        }
    }

    // MARK: - Listeners (stay in sync with external changes, e.g. Control Center)

    private func setupDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.setupMuteListener()
                self?.refresh()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, listener
        ) == noErr else { return }
        defaultDeviceListener = (address, listener)
    }

    private func setupMuteListener() {
        removeDeviceListeners()
        let deviceID = systemInputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        guard AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, nil, listener) == noErr else { return }
        deviceListeners.append((deviceID, muteAddr, listener))
    }

    private func removeDeviceListeners() {
        for (deviceID, address, listener) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, listener)
        }
        deviceListeners.removeAll()
    }
}
