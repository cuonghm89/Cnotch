import Defaults
import Foundation
import IOKit
import IOKit.usb

/// Announces USB devices as they are plugged in and pulled out.
///
/// The announcements go through `VolumeManager`'s queue rather than a second
/// one of their own: the notch has a single popup slot, so plugging a drive in
/// while a Bluetooth accessory connects would otherwise leave one of the two
/// silently dropped.
///
/// IOKit hands every *already attached* device to the first drain of the
/// matching iterator -- that's also how a Mac's built-in USB hardware arrives,
/// and the drain is mandatory or the notification never arms. So the first
/// pass only records names, and announcing starts from the second.
@MainActor
final class USBDeviceMonitor: ObservableObject {
    static let shared = USBDeviceMonitor()

    struct Device: Identifiable, Equatable {
        let id: UInt64
        let name: String
    }

    /// Everything currently attached over USB, for the "connected devices"
    /// list. Kept up to date whether or not announcements are switched on --
    /// the list and the popups are separate settings.
    @Published private(set) var connectedDevices: [Device] = []

    private var notifyPort: IONotificationPortRef?
    private var attachedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var isSeeded = false

    /// Product names by registry entry ID. A terminated service can no longer
    /// be asked for its own name, so the name has to have been kept from when
    /// the device attached.
    private var names: [UInt64: String] = [:]

    private init() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let onAttached: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handleAttached(iterator) }
        }
        let onTerminated: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handleTerminated(iterator) }
        }

        // One matching dictionary per registration -- each call consumes a
        // reference to the one it's handed.
        IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, IOServiceMatching(kIOUSBHostDeviceClassName),
            onAttached, refcon, &attachedIterator
        )
        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, IOServiceMatching(kIOUSBHostDeviceClassName),
            onTerminated, refcon, &terminatedIterator
        )

        handleAttached(attachedIterator)
        handleTerminated(terminatedIterator)
        isSeeded = true
    }

    private func handleAttached(_ iterator: io_iterator_t) {
        var announcements: [VolumeManager.DeviceAnnouncement] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            let name = Self.productName(of: service)
            names[entryID] = name
            if isSeeded, Defaults[.showUSBDeviceConnectionIndicator] {
                announcements.append(.init(name: name, icon: "cable.connector", batteryPercentage: nil))
            }
        }
        rebuildConnectedDevices()
        announce(announcements)
    }

    private func handleTerminated(_ iterator: io_iterator_t) {
        var announcements: [VolumeManager.DeviceAnnouncement] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            let name = names.removeValue(forKey: entryID) ?? Self.productName(of: service)
            if isSeeded, Defaults[.showUSBDeviceConnectionIndicator] {
                announcements.append(
                    .init(title: "Disconnected", name: name, icon: "cable.connector", batteryPercentage: nil)
                )
            }
        }
        rebuildConnectedDevices()
        announce(announcements)
    }

    private func rebuildConnectedDevices() {
        connectedDevices = names
            .map { Device(id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private func announce(_ announcements: [VolumeManager.DeviceAnnouncement]) {
        guard !announcements.isEmpty else { return }
        VolumeManager.shared.announceDeviceConnections(announcements)
    }

    /// A composite device (most keyboards, most drives) leaves its own name
    /// empty and only fills it in on one of these properties, so try each in
    /// turn before falling back to the registry entry's node name.
    private static func productName(of service: io_service_t) -> String {
        for key in ["USB Product Name", kUSBProductString, "Product Name"] {
            if let value = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String, !value.isEmpty {
                return value
            }
        }
        var node = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetName(service, &node) == KERN_SUCCESS {
            let name = String(cString: node)
            if !name.isEmpty { return name }
        }
        return "USB Device"
    }
}
