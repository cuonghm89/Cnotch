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
        let icon: String
    }

    /// Everything currently attached over USB, for the "connected devices"
    /// list. Kept up to date whether or not announcements are switched on --
    /// the list and the popups are separate settings.
    @Published private(set) var connectedDevices: [Device] = []

    private var notifyPort: IONotificationPortRef?
    private var attachedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var isSeeded = false

    /// By registry entry ID. A terminated service can no longer be asked for
    /// its own name or class, so both have to have been kept from when the
    /// device attached.
    private var devices: [UInt64: Device] = [:]

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
            let device = Device(
                id: entryID,
                name: Self.productName(of: service),
                icon: Self.icon(of: service)
            )
            devices[entryID] = device
            if isSeeded, Defaults[.showUSBDeviceConnectionIndicator] {
                announcements.append(.init(name: device.name, icon: device.icon, batteryPercentage: nil))
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
            let device = devices.removeValue(forKey: entryID)
                ?? Device(id: entryID, name: Self.productName(of: service), icon: Self.icon(of: service))
            if isSeeded, Defaults[.showUSBDeviceConnectionIndicator] {
                announcements.append(
                    .init(title: "Disconnected", name: device.name, icon: device.icon, batteryPercentage: nil)
                )
            }
        }
        rebuildConnectedDevices()
        announce(announcements)
    }

    private func rebuildConnectedDevices() {
        connectedDevices = devices.values.sorted { $0.name < $1.name }
    }

    private func announce(_ announcements: [VolumeManager.DeviceAnnouncement]) {
        guard !announcements.isEmpty else { return }
        VolumeManager.shared.announceDeviceConnections(announcements)
    }

    /// A composite device keeps `bDeviceClass` at 0 and only says what it
    /// actually is on its interfaces, so the icon has to come from those. A
    /// keyboard and a mouse share class 3 and are told apart by the boot
    /// protocol; anything unrecognised keeps the generic connector.
    private static func icon(of service: io_service_t) -> String {
        let plane = strdup(kIOServicePlane)
        defer { free(plane) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, plane, &iterator) == KERN_SUCCESS else {
            return "cable.connector"
        }
        defer { IOObjectRelease(iterator) }

        var fallback: String?
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard let interfaceClass = number(child, "bInterfaceClass") else { continue }
            switch (interfaceClass, number(child, "bInterfaceProtocol")) {
            // Boot protocol 1/2 is definitive, so take it and stop looking.
            case (3, 1): return "keyboard"
            case (3, 2): return "computermouse"
            case (8, _): return "externaldrive"
            // A composite device often leads with an interface that says less
            // than a later one does (a keyboard's consumer-control interface
            // reports class 3 with no protocol), so keep looking for a better
            // answer before settling for these.
            case (1, _): fallback = fallback ?? "headphones"
            case (6, _), (14, _): fallback = fallback ?? "camera"
            case (7, _): fallback = fallback ?? "printer"
            case (3, _): fallback = fallback ?? "keyboard"
            default: continue
            }
        }
        return fallback ?? "cable.connector"
    }

    private static func number(_ service: io_service_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
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
