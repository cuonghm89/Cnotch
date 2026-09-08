//
//  ShareServiceFinder.swift
//  CNotch
//
//  Created by Alexander on 2025-10-06.
//

import Cocoa

/// Looks up which sharing services (AirDrop, Messages, Mail, etc.) can
/// handle a set of items.
///
/// This used to go through NSSharingServicePicker, anchored to an NSView
/// that was never added to any window -- the picker needs a real window to
/// present in, so it silently never called back into its delegate and this
/// always fell through to a 2-second timeout returning an empty list.
/// NSSharingService.sharingServices(forItems:) queries the same information
/// directly, synchronously, with no picker UI involved at all.
enum ShareServiceFinder {
    static func findApplicableServices(for items: [Any]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: items)
    }
}
