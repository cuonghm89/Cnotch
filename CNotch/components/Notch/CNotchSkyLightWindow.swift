//
//  CNotchSkyLightWindow.swift
//  CNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import os
import SkyLightWindow
import Defaults
import Combine

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class CNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        // Deliver the click instead of spending it on becoming key.
        //
        // A floating panel that is not key takes the first click to become
        // one, and the control under the pointer never sees it -- which is
        // why the ⋯ menu needed two clicks even with the app already active:
        //
        //     CLICK active=true  window=CNotchSkyLightWindow   <- became key
        //     CLICK active=true  window=CNotchSkyLightWindow   <- opened the menu
        //     ACTION                                           <- item chosen
        //
        // With this, the panel takes key status only when something actually
        // needs it, and clicks reach their control on the way.
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        animationBehavior = .none
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }
    
    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
        level = .screenSaver
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
        level = .mainMenu + 3
    }
    
    private var observers: Set<AnyCancellable> = []

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CNotchFileDropContainerView: NSView {
    override var isFlipped: Bool { true }

    /// Takes the click that lands while the app is inactive.
    ///
    /// This is the view AppKit asks -- it is what the notch's content sits
    /// inside -- and the default answer is no, so the first click of any
    /// interaction was spent activating and never delivered. Measured:
    /// `CLICK received, active=false` with nothing following it, then a
    /// second click with `active=true` that finally reached the menu.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var acceptsFileDrop: () -> Bool = { false }
    var onFileDrop: ([URL]) -> Bool = { _ in false }
    private var acceptsCurrentDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        acceptsCurrentDrag = acceptsFileDrop()
        #if DEBUG
        AppLog.shelf.debug("Shelf container draggingEntered: \(self.acceptsCurrentDrag, privacy: .public)")
        #endif
        return acceptsCurrentDrag ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsCurrentDrag ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        acceptsCurrentDrag = false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsCurrentDrag && !fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { acceptsCurrentDrag = false }
        let accepted = acceptsCurrentDrag && onFileDrop(fileURLs(from: sender.draggingPasteboard))
        #if DEBUG
        AppLog.shelf.debug("Shelf container performDragOperation: \(accepted, privacy: .public)")
        #endif
        return accepted
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options)?
            .compactMap { $0 as? URL } ?? []
    }
}
