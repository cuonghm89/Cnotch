//
//  ShelfItemView.swift
//  CNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: CNotchViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding()
            }
            .transaction { transaction in
                transaction.animation = nil
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
    }

    private var shelfItems: some DynamicViewContent {
        ForEach(tvm.items) { item in
            ShelfItemView(item: item)
                .environmentObject(quickLookService)
        }
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        #if SDK_MACOS_27
                        if #available(macOS 27, *) {
                            shelfItems.reorderable()
                        } else {
                            shelfItems
                        }
                        #else
                        shelfItems
                        #endif
                    }
                }
                .shelfReorderContainer()
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}

private extension View {
    /// Receives the drop half of a shelf reorder.
    ///
    /// Two gates, for two different questions. `#available` is the runtime
    /// one: the shelf still has to run on macOS 14, where it keeps the order
    /// things arrived in, as it always has. `SDK_MACOS_27` is the compile-time
    /// one, set by the project only when building against the macOS 27 SDK --
    /// GitHub's runners ship Xcode 26.6 and have no `reorderable()` to call,
    /// and a release that cannot compile helps nobody. The feature switches
    /// itself on the first time CI builds with Xcode 27; nothing here needs to
    /// change for that.
    @ViewBuilder
    func shelfReorderContainer() -> some View {
        #if SDK_MACOS_27
        if #available(macOS 27, *) {
            reorderContainer(for: ShelfItem.self) { difference in
                let target: ShelfItem.ID?
                switch difference.destination.position {
                case .before(let id): target = id
                case .end: target = nil
                }
                ShelfStateViewModel.shared.move(ids: difference.sources, before: target)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
