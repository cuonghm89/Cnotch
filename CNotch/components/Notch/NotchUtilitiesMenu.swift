import Defaults
import SwiftUI

/// There's no real Bluetooth SF Symbol (Apple doesn't ship the trademarked
/// rune as one -- `Image(systemName: "bluetooth")` silently renders nothing),
/// so draw the actual logo: two triangles sharing a crossing point in the
/// middle, traced as one continuous outline top -> upper-right -> lower-left
/// -> bottom -> lower-right -> upper-left -> back to top. Proportions checked
/// against the system's own IOBluetoothUI.framework/Resources/Bluetooth.icns.
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

    /// A menu item's icon has to be a real NSImage (a Shape doesn't render
    /// there the way an SF Symbol does), so pre-render this one once via
    /// ImageRenderer and mark it as a template so it tints like the others.
    @MainActor static let menuIcon: NSImage = {
        let renderer = ImageRenderer(content:
            BluetoothGlyph()
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .miter, miterLimit: 4))
                .frame(width: 14, height: 14)
        )
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

/// Consolidates the Quick Note, Pomodoro, Voice Memo, and connected-Bluetooth-
/// devices triggers into one header icon. Each is independently optional,
/// and showing them as separate always-visible icons overflowed the notch
/// header's width once more than one or two were enabled at the same time.
struct NotchUtilitiesMenu: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @ObservedObject private var recorder = VoiceMemoRecorder.shared
    @ObservedObject private var volumeManager = VolumeManager.shared
    @State private var showQuickNote = false
    @State private var noteText = ""
    @State private var isSavingNote = false
    @State private var noteSaveFailed = false

    var body: some View {
        Menu {
            if Defaults[.quickNoteEnabled] {
                Button("Quick Note", systemImage: "square.and.pencil") {
                    showQuickNote = true
                }
            }
            if Defaults[.pomodoroButtonEnabled] {
                Menu("Pomodoro Timer", systemImage: "timer") {
                    ForEach([5, 15, 25], id: \.self) { minutes in
                        Button("\(minutes) min") {
                            pomodoro.start(minutes: minutes)
                        }
                    }
                    if pomodoro.isRunning {
                        Button("Cancel Timer", role: .destructive) {
                            pomodoro.cancel()
                        }
                    }
                }
            }
            if Defaults[.voiceMemoButtonEnabled] {
                Button(
                    recorder.isRecording ? "Stop Voice Memo" : "Record Voice Memo",
                    systemImage: recorder.isRecording ? "stop.circle" : "mic"
                ) {
                    recorder.toggle()
                }
            }
            if Defaults[.showBluetoothDeviceConnectionIndicator]
                && Defaults[.showConnectedBluetoothDevicesInNotch]
                && !volumeManager.connectedBluetoothAccessories.isEmpty
            {
                Menu {
                    ForEach(volumeManager.connectedBluetoothAccessories) { device in
                        // A plain Text row renders dimmed/disabled in a Menu
                        // since it isn't interactive -- an inert Button (no
                        // action) keeps the normal, non-greyed-out label.
                        Button(device.batteryPercentage.map { "\(device.name) — \($0)%" } ?? device.name) {}
                    }
                } label: {
                    Label {
                        Text("Connected Devices")
                    } icon: {
                        Image(nsImage: BluetoothGlyph.menuIcon)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $showQuickNote, arrowEdge: .bottom) {
            quickNoteEditor
        }
    }

    private var quickNoteEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Note")
                .font(.headline)

            TextEditor(text: $noteText)
                .font(.body)
                .frame(width: 260, height: 120)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.secondary.opacity(0.3)))

            if noteSaveFailed {
                Text("Couldn't save to Notes.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showQuickNote = false
                }
                Button("Save to Notes") {
                    saveNote()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingNote)
            }
        }
        .padding(16)
        .onChange(of: showQuickNote) { _, presented in
            if !presented {
                noteText = ""
                noteSaveFailed = false
            }
        }
    }

    private func saveNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSavingNote = true
        noteSaveFailed = false

        let body = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "<br>")

        let script = """
        tell application "Notes"
            tell default account
                make new note with properties {body:"\(body)"}
            end tell
        end tell
        """

        Task {
            do {
                try await AppleScriptHelper.executeVoid(script)
                await MainActor.run { showQuickNote = false; isSavingNote = false }
            } catch {
                await MainActor.run { isSavingNote = false; noteSaveFailed = true }
            }
        }
    }
}
