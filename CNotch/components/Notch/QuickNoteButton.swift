import SwiftUI

/// A small button in the open notch header that lets you jot a quick note
/// and save it straight into Notes.app, via AppleScript (the app already
/// carries the apple-events entitlement for this).
struct QuickNoteButton: View {
    @State private var isPresented = false
    @State private var text = ""
    @State private var isSaving = false
    @State private var saveFailed = false

    var body: some View {
        HoverButton(
            icon: "square.and.pencil",
            iconColor: .white,
            showsHoverHighlight: false,
            accessibilityLabel: "Quick Note",
            action: { isPresented = true }
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Note")
                    .font(.headline)

                TextEditor(text: $text)
                    .font(.body)
                    .frame(width: 260, height: 120)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.secondary.opacity(0.3)))

                if saveFailed {
                    Text("Couldn't save to Notes.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        isPresented = false
                    }
                    Button("Save to Notes") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .padding(16)
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                text = ""
                saveFailed = false
            }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        saveFailed = false

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
                await MainActor.run { isPresented = false; isSaving = false }
            } catch {
                await MainActor.run { isSaving = false; saveFailed = true }
            }
        }
    }
}
