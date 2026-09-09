import Defaults
import SwiftUI

/// There's no real Bluetooth SF Symbol (Apple doesn't ship the trademarked
/// rune as one -- `Image(systemName: "bluetooth")` silently renders nothing),
/// so draw the actual logo: two triangles sharing a crossing point in the
/// middle, traced as one continuous outline top -> upper-right -> lower-left
/// -> bottom -> lower-right -> upper-left -> back to top.
struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        let top = point(0.5, 0.08)
        let upperRight = point(0.78, 0.32)
        let lowerLeft = point(0.22, 0.68)
        let bottom = point(0.5, 0.92)
        let lowerRight = point(0.78, 0.68)
        let upperLeft = point(0.22, 0.32)

        var path = Path()
        path.move(to: top)
        path.addLine(to: upperRight)
        path.addLine(to: lowerLeft)
        path.addLine(to: bottom)
        path.addLine(to: lowerRight)
        path.addLine(to: upperLeft)
        path.closeSubpath()
        return path
    }
}

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
        Button {
            showDevices.toggle()
        } label: {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: 30, height: 30)
                .overlay {
                    BluetoothGlyph()
                        .stroke(.white, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .miter, miterLimit: 4))
                        .frame(width: 16, height: 16)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connected Bluetooth devices")
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
