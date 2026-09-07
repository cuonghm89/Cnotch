import SwiftUI

/// Quick actions shown on the compact notch right after a new screenshot
/// is detected (see `ScreenshotWatcher`).
struct ScreenshotQuickActionsIndicator: View {
    let item: ExpandedItem
    let physicalNotchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)

            Rectangle()
                .fill(.black)
                .frame(width: physicalNotchWidth)

            HStack(spacing: 10) {
                actionButton(systemImage: "doc.on.doc") { copy() }
                actionButton(systemImage: "folder") { reveal() }
                actionButton(systemImage: "trash") { delete() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
        }
    }

    private func actionButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        guard let url = item.url, let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        dismiss()
    }

    private func delete() {
        guard let url = item.url else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        dismiss()
    }

    private func reveal() {
        guard let url = item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        dismiss()
    }

    private func dismiss() {
        CNotchViewCoordinator.shared.toggleExpandingView(status: false, type: .screenshot)
    }
}
