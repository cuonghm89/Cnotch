import SwiftUI

/// Shown on the compact notch while a voice memo (see `VoiceMemoRecorder`)
/// is being recorded.
struct VoiceMemoIndicator: View {
    @ObservedObject var recorder: VoiceMemoRecorder
    let physicalNotchWidth: CGFloat

    private var timeText: String {
        String(format: "%d:%02d", recorder.elapsedSeconds / 60, recorder.elapsedSeconds % 60)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(timeText)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)

            Rectangle()
                .fill(.black)
                .frame(width: physicalNotchWidth)

            Button {
                recorder.toggle()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
        }
    }
}
