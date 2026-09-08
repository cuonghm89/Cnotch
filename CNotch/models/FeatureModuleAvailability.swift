enum FeatureModuleAvailability {
    static func isAvailable(
        id: FeatureModuleID,
        moduleIsAvailable: Bool,
        isInstalled: Bool,
        isMainFeatureEnabled: Bool,
        screenIsLocked: Bool
    ) -> Bool {
        guard moduleIsAvailable && isInstalled && isMainFeatureEnabled else { return false }
        // Clipboard, Shelf, Calendar, and Camera all expose personal data --
        // restrict the notch to Home (music/HUD) while the screen is locked
        // so someone at a locked Mac can't browse them without signing in.
        return id == .home || !screenIsLocked
    }

    static func isMainFeatureEnabled(
        for module: FeatureModuleID,
        clipboardHistoryEnabled: Bool,
        shelfEnabled: Bool,
        calendarEnabled: Bool,
        cameraEnabled: Bool
    ) -> Bool {
        switch module {
        case .home:
            true
        case .clipboard:
            clipboardHistoryEnabled
        case .shelf:
            shelfEnabled
        case .calendar:
            calendarEnabled
        case .camera:
            cameraEnabled
        }
    }
}
