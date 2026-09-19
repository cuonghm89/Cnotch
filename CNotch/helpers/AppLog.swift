//
//  AppLog.swift
//  CNotch
//
//  The app's logging, in one place.
//

import Foundation
import os

/// Diagnostics go to the unified log, not to stdout.
///
/// `print` wrote to a stream nobody reads in a shipped app -- it still built
/// every string, and it could not redact anything. `NSLog` at least reached
/// the log, but with no category to filter on and no level to quieten. A
/// `Logger` is filterable by subsystem and category, carries a level so the
/// chatty lines cost nothing in production, is readable after the fact in
/// Console.app, and redacts interpolated values by default.
///
/// The privacy convention here, applied deliberately rather than by habit:
/// error text the system wrote is marked public, because that is the whole
/// diagnostic value and no user typed it. Everything the user supplied --
/// paths, file names, device names, clipboard contents -- keeps the default
/// and shows as `<private>`. Counts and flags are public, because a number
/// cannot identify anyone.
///
/// Read it with:
///     log stream --predicate 'subsystem == "com.cuonghm89.cnotch"' --level debug
/// A namespace of its own rather than an extension on `Logger`: two of the
/// packages this app links declare a `Logger` of their own, so `Logger.shelf`
/// resolved to the wrong type in whichever files imported them.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.cuonghm89.cnotch"

    static let shelf = os.Logger(subsystem: subsystem, category: "shelf")
    static let media = os.Logger(subsystem: subsystem, category: "media")
    static let calendar = os.Logger(subsystem: subsystem, category: "calendar")
    static let camera = os.Logger(subsystem: subsystem, category: "camera")
    static let display = os.Logger(subsystem: subsystem, category: "display")
    static let shortcuts = os.Logger(subsystem: subsystem, category: "shortcuts")
}
