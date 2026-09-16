import SwiftUI

/// Quick actions shown on the compact notch right after a new screenshot is
/// detected (see `ScreenshotWatcher`), and after a download finishes (see
/// `DownloadWatcher`) -- the actions wanted are the same in both cases.
struct ScreenshotQuickActionsIndicator: View {
    let item: ExpandedItem
    let physicalNotchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                // Text(someString) picks the overload that does NOT go
                // through the String Catalog, which is why this strip stayed
                // English while the rest of the app translated.
                //
                // The label is the short one, not the file's name: the black
                // rectangle below has to sit exactly over the physical notch,
                // which only works while the two sides of it are equal, so
                // this side can't be widened. What fits is about a dozen
                // characters -- enough for "Downloaded", not for a filename,
                // which came out as "Bao-...-3.pdf". The file is one click
                // away behind Reveal instead.
                Text(LocalizedStringKey(item.title))
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
        guard let url = item.url else { return }
        NSPasteboard.general.clearContents()
        // A screenshot is most useful on the pasteboard as the image itself,
        // ready to paste into a message. Any other download is an arbitrary
        // file, so copy the file instead.
        if let image = NSImage(contentsOf: url), item.type == .screenshot {
            NSPasteboard.general.writeObjects([image])
        } else {
            NSPasteboard.general.writeObjects([url as NSURL])
        }
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
        CNotchViewCoordinator.shared.toggleExpandingView(status: false, type: item.type)
    }
}
