import AppKit
import SwiftUI

/// A small floating window for the panels that hang off the notch menu.
///
/// These were `.popover`s, and the first press never showed one. What the
/// measurements said, in order: the check ran in 0.28s; the panel's body was
/// re-evaluated with the result; and the second press ran no `.task` at all
/// yet displayed content. So the popover was being built and rendered on the
/// first press and simply never put on screen -- the second press displayed
/// what the first had already made.
///
/// Three attempts to make `.popover` behave failed: activating the app first,
/// deferring to the next run-loop turn, and giving the view its own state.
/// A menu item's action runs inside the menu's tracking loop while its anchor
/// view is being torn down, and negotiating with that is a losing game.
///
/// So the window is ours. `makeKeyAndOrderFront` is not a request.
@MainActor
final class NotchPopoutWindow: NSObject, NSWindowDelegate {
    static let shared = NotchPopoutWindow()

    private var panel: NSPanel?
    private var identifier: String?

    /// Shows `content`, replacing whatever was open.
    ///
    /// Choosing a menu item always shows its panel. It used to toggle, the
    /// way a popover does -- but a popover closes itself when you click away,
    /// and this window stays put, so the second press closed what the first
    /// had opened. While the window was also opening on the wrong display
    /// that was invisible: press, nothing seen; press again, it closed
    /// unseen; press a third time, it appeared. Two presses, apparently.
    ///
    /// Already open on the right screen? Bring it forward rather than making
    /// the user hunt for it.
    func show(id: String, @ViewBuilder content: () -> some View) {
        if identifier == id, let existing = panel {
            existing.setFrameTopLeftPoint(Self.topLeft(for: existing.frame.size))
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        close()

        let hosting = NSHostingView(rootView: content())
        hosting.setFrameSize(hosting.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Above the notch, which sits at `.mainMenu + 3`, or it opens behind
        // the very thing it was summoned from.
        panel.level = .mainMenu + 4
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.delegate = self
        panel.setFrameTopLeftPoint(Self.topLeft(for: hosting.fittingSize))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.identifier = id
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        identifier = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        identifier = nil
    }

    /// Directly under the notch window, on whichever display that window is
    /// actually on.
    ///
    /// The first version asked for the screen with a notch, falling back to
    /// `NSScreen.main`, and with two displays attached it opened at x=2644 --
    /// off on the external monitor while the notch was on the built-in. The
    /// window was shown correctly every time, first press included; it was
    /// shown where nobody was looking, which from the outside is
    /// indistinguishable from not opening at all.
    ///
    /// So the anchor is the notch window itself. It cannot disagree with
    /// where the notch is, because it is where the notch is.
    private static func topLeft(for size: NSSize) -> NSPoint {
        if let notch = NSApp.windows.first(where: { $0 is CNotchSkyLightWindow || $0 is CNotchWindow }),
           let screen = notch.screen {
            // The notch window is used to pick the *display*, not the height:
            // it is nearly as tall as the screen, so anchoring to its bottom
            // edge dropped this panel to the very bottom, over everything.
            // Vertically it belongs just under the menu bar, like the notch.
            return NSPoint(
                x: min(max(screen.frame.midX - size.width / 2, screen.frame.minX + 8),
                       screen.frame.maxX - size.width - 8),
                y: screen.frame.maxY - max(screen.safeAreaInsets.top, 28) - 6
            )
        }
        // Nothing to anchor to: the screen the pointer is on beats a guess.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return NSPoint(x: 100, y: 100) }
        return NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - max(screen.safeAreaInsets.top, 28) - 6
        )
    }
}
