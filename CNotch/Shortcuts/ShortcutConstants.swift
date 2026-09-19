//
//  Constants.swift
//  CNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
    // The system's own screenshot combinations, taken over wholesale.
    //
    // Those are the keys the hands already know, and macOS gives them up
    // without a fight: the shortcut recorder refuses anything the system
    // still holds, so on a Mac where Screenshots are switched off in
    // Keyboard Settings these are simply free -- and on one where they are
    // not, the system wins and the user picks something else.
    static let captureScreenshot = Self("captureScreenshot", default: .init(.four, modifiers: [.command, .shift]))
    static let captureFullScreen = Self("captureFullScreen", default: .init(.three, modifiers: [.command, .shift]))
}
