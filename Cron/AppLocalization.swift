import Foundation

enum AppLocalization {
    static let supportedLanguageIdentifiers: Set<String> = [
        "sq", "hy", "be", "bs", "bg", "ca", "hr", "cs", "da", "nl",
        "en", "et", "fi", "fr", "ka", "de", "el", "hu", "is", "ga",
        "it", "lv", "lt", "lb", "mk", "mt", "no", "pl", "pt", "ro",
        "ru", "sr", "sk", "sl", "es", "sv", "tr", "uk",
        "zh-Hans", "hi", "ar", "bn", "id"
    ]

    static var currentLanguageIdentifier: String {
        let selected = UserDefaults.standard.string(forKey: AppSettingsKeys.languageIdentifier)
            ?? AppLanguageOption.automaticIdentifier

        let requestedIdentifier = selected == AppLanguageOption.automaticIdentifier
            ? Locale.autoupdatingCurrent.identifier
            : selected

        return resourceIdentifier(for: requestedIdentifier)
    }

    static var currentLocale: Locale {
        Locale(identifier: currentLanguageIdentifier)
    }

    static func localized(_ key: String) -> String {
        let languageIdentifier = currentLanguageIdentifier

        if let path = Bundle.main.path(forResource: languageIdentifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)

            if value != key {
                return value
            }
        }

        if languageIdentifier != "en",
           let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }

        return key
    }

    static func resourceIdentifier(for identifier: String) -> String {
        if supportedLanguageIdentifiers.contains(identifier) {
            return identifier
        }

        let locale = Locale(identifier: identifier)
        let languageCode = locale.language.languageCode?.identifier ?? identifier

        if languageCode == "zh" {
            return "zh-Hans"
        }

        if languageCode == "nb" || languageCode == "nn" {
            return "no"
        }

        if supportedLanguageIdentifiers.contains(languageCode) {
            return languageCode
        }

        return "en"
    }
}

func L(_ key: String) -> String {
    AppLocalization.localized(key)
}
