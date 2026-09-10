import Defaults
import SwiftUI

/// Resolves a clipboard entry's source-app icon from its bundle ID. There's
/// no need to persist the icon itself -- the app is still installed in the
/// overwhelming majority of cases, so looking it up on demand and caching in
/// memory is simpler than managing an on-disk icon cache.
enum ClipboardSourceAppIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] {
            return cached
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        cache[bundleID] = icon
        return icon
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @EnvironmentObject var vm: CNotchViewModel
    @Default(.clipboardSearchMode) private var searchMode
    @State private var searchQuery = ""
    @State private var selectedEntryID: ClipboardEntry.ID?
    @State private var selectedAppFilter: String?

    /// Distinct source apps currently represented in history, alphabetical,
    /// for the filter menu -- entries with no recorded source app (older
    /// history, or a copy CNotch couldn't attribute) are excluded since
    /// there's nothing to filter them by.
    private var sourceApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        var result: [(bundleID: String, name: String)] = []
        for entry in store.entries {
            guard let bundleID = entry.sourceAppBundleID, seen.insert(bundleID).inserted else { continue }
            result.append((bundleID, entry.sourceAppName ?? bundleID))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedAppName: String? {
        guard let selectedAppFilter else { return nil }
        return sourceApps.first { $0.bundleID == selectedAppFilter }?.name
    }

    private var filteredEntries: [ClipboardEntry] {
        let searched = ClipboardEntrySearch.results(for: searchQuery, in: store.entries, mode: searchMode)
        guard let selectedAppFilter else { return searched }
        return searched.filter { $0.sourceAppBundleID == selectedAppFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if store.entries.isEmpty {
                ContentUnavailableView("Clipboard is empty", systemImage: "clipboard")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No clipboard matches",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search.")
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            ClipboardEntryRow(entry: entry, isSelected: selectedEntryID == entry.id) {
                                guard selectedEntryID == nil else { return }
                                withAnimation(.easeOut(duration: 0.12)) {
                                    selectedEntryID = entry.id
                                }
                                store.copy(entry)
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(160))
                                    guard selectedEntryID == entry.id else { return }
                                    vm.close()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                }
                .contentMargins(.top, 0, for: .scrollContent)
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            if sourceApps.count > 1 {
                appFilterMenu
                Divider().frame(height: 14)
            }

            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search clipboard", text: $searchQuery)
                .textFieldStyle(.plain)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear clipboard search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 0)
        .padding(.bottom, 8)
    }

    /// A dropdown instead of a chip row -- with dozens of source apps in a
    /// long-lived history, a row of chips would either wrap over several
    /// lines or need horizontal scrolling to reach anything past the first
    /// handful; a list scrolls in place and takes no space collapsed.
    private var appFilterMenu: some View {
        Menu {
            Button {
                selectedAppFilter = nil
            } label: {
                if selectedAppFilter == nil {
                    Label("All", systemImage: "checkmark")
                } else {
                    Text("All")
                }
            }
            Divider()
            ForEach(sourceApps, id: \.bundleID) { app in
                Button {
                    selectedAppFilter = app.bundleID
                } label: {
                    appMenuRowLabel(app: app, isSelected: selectedAppFilter == app.bundleID)
                }
            }
        } label: {
            HStack(spacing: 3) {
                if let selectedAppFilter, let icon = ClipboardSourceAppIcon.icon(forBundleID: selectedAppFilter) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(verbatim: selectedAppName ?? String(localized: "All"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Filter clipboard by app")
    }

    /// App names are user data (proper nouns from other apps' own
    /// Info.plist), not UI copy -- Text(verbatim:) skips the String Catalog
    /// lookup the rest of this menu's labels go through.
    @ViewBuilder
    private func appMenuRowLabel(app: (bundleID: String, name: String), isSelected: Bool) -> some View {
        let icon = ClipboardSourceAppIcon.icon(forBundleID: app.bundleID)
        if let icon {
            Label {
                Text(verbatim: app.name)
            } icon: {
                Image(nsImage: icon)
            }
        } else {
            Text(verbatim: app.name)
        }
    }
}

private struct ClipboardEntryRow: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    let entry: ClipboardEntry
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onSelect()
            } label: {
                HStack(spacing: 10) {
                    entryPreview
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if let bundleID = entry.sourceAppBundleID,
                               let icon = ClipboardSourceAppIcon.icon(forBundleID: bundleID)
                            {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                    .background(Circle().fill(.black))
                                    .clipShape(Circle())
                                    .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                                    .offset(x: 4, y: 4)
                            }
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.kind == .url ? "URL" : entry.kind == .image ? "Image" : "Text")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(entry.timestamp, style: .time)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary.opacity(0.8))
                            if let sourceAppName = entry.sourceAppName {
                                Text("· \(sourceAppName)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary.opacity(0.8))
                                    .lineLimit(1)
                            }
                        }
                        Text(detail)
                            .lineLimit(2)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.delete(entry)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? .red.opacity(0.8) : .secondary)
            .accessibilityLabel("Delete clipboard entry")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.18) : isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
        )
        .onHover { isHovering = $0 }
    }

    private var detail: String {
        if entry.kind == .image, let text = entry.extractedText, !text.isEmpty {
            return text
        }
        guard entry.kind == .image,
              let data = store.imageData(for: entry),
              let image = NSImage(data: data)
        else { return entry.preview }
        return "\(Int(image.size.width)) × \(Int(image.size.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
    }

    @ViewBuilder
    private var entryPreview: some View {
        if entry.kind == .image, let data = store.imageData(for: entry), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: entry.kind == .url ? "link" : "doc.on.clipboard")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

struct ClipboardHUD: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    let entry: ClipboardEntry
    let physicalNotchMaskSize: CGSize

    var body: some View {
        if entry.kind == .image {
            ZStack {
                HStack(spacing: 10) {
                    Image(systemName: "clipboard.fill")
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    if let data = store.imageData(for: entry), let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 46, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(.black)
                        .frame(
                            width: physicalNotchMaskSize.width,
                            height: physicalNotchMaskSize.height
                        )
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "clipboard.fill")
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                }
                GeometryReader { geometry in
                    MarqueeText(
                        .constant(entry.preview),
                        font: .system(size: 12),
                        nsFont: .caption1,
                        textColor: .secondary,
                        minDuration: 0.15,
                        frameWidth: geometry.size.width,
                        centerWhenFits: true
                    )
                }
                .frame(height: 16)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
