import Defaults
import SwiftUI

/// One header icon standing in for the whole connected-accessories list --
/// showing every device inline (like the compact weather/CPU chips) would
/// grow without bound as more devices connect and overflow the header, which
/// already has to fit weather, system stats, and other utility icons.
struct ConnectedBluetoothDevicesMenu: View {
    @ObservedObject private var volumeManager = VolumeManager.shared
    @State private var showDevices = false

    private var devices: [VolumeManager.ConnectedBluetoothAccessory] {
        volumeManager.connectedBluetoothAccessories
    }

    var body: some View {
        HoverButton(
            icon: "cable.connector",
            iconColor: .white,
            showsHoverHighlight: false,
            accessibilityLabel: "Connected Bluetooth devices",
            action: { showDevices.toggle() }
        )
        .popover(isPresented: $showDevices, arrowEdge: .bottom) {
            devicesList
        }
    }

    private var devicesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connected Devices")
                .font(.headline)

            ForEach(devices) { device in
                HStack(spacing: 10) {
                    Image(systemName: device.icon)
                        .frame(width: 18)
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 12)
                    if let battery = device.batteryPercentage {
                        Text("\(battery)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 220, alignment: .leading)
    }
}
