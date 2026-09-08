import Defaults
import SwiftUI

/// Applies the user's chosen in-app language (Settings > General), overriding
/// the system locale for text lookup in this view's `Localizable.xcstrings`
/// translations. A no-op when the user picked "System".
struct LanguageOverride: ViewModifier {
    @Default(.appLanguage) private var appLanguage

    func body(content: Content) -> some View {
        if let locale = appLanguage.locale {
            content.environment(\.locale, locale)
        } else {
            content
        }
    }
}

extension View {
    func applyAppLanguage() -> some View {
        modifier(LanguageOverride())
    }
}
