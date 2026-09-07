import SwiftUI

/// Header button that starts a Pomodoro-style focus timer, shown via
/// `PomodoroIndicator` on the compact notch while running.
struct PomodoroButton: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @State private var isPresented = false

    var body: some View {
        HoverButton(
            icon: "timer",
            iconColor: .white,
            showsHoverHighlight: false,
            accessibilityLabel: "Pomodoro Timer",
            action: {
                if pomodoro.isRunning {
                    pomodoro.cancel()
                } else {
                    isPresented = true
                }
            }
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Start a Focus Timer")
                    .font(.headline)
                HStack(spacing: 8) {
                    ForEach([5, 15, 25], id: \.self) { minutes in
                        Button("\(minutes)m") {
                            pomodoro.start(minutes: minutes)
                            isPresented = false
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}
