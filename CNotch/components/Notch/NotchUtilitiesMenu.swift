import Defaults
import SwiftUI

/// Consolidates the Quick Note, Pomodoro, and Voice Memo triggers into one
/// header icon. Each is independently optional (Settings > Advanced), and
/// showing them as separate always-visible icons overflowed the notch
/// header's width once more than one or two were enabled at the same time.
struct NotchUtilitiesMenu: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @ObservedObject private var recorder = VoiceMemoRecorder.shared
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
                Menu("Pomodoro Timer") {
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
