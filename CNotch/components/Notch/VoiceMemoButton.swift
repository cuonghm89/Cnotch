import SwiftUI

/// Header button that starts/stops a quick voice memo recording (see
/// `VoiceMemoRecorder`), saved straight into the Shelf.
struct VoiceMemoButton: View {
    @ObservedObject private var recorder = VoiceMemoRecorder.shared

    var body: some View {
        HoverButton(
            icon: recorder.isRecording ? "mic.fill" : "mic",
            iconColor: recorder.isRecording ? .red : .white,
            showsHoverHighlight: false,
            accessibilityLabel: recorder.isRecording ? "Stop Recording" : "Record Voice Memo",
            action: { recorder.toggle() }
        )
    }
}
