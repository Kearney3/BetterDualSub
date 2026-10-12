import Foundation

enum AppLocalization {
    static let languagePreferenceKey = "appLanguage"

    static let defaultLanguage = subtitleSystemLanguage()

    static var language: String { subtitleCurrentLanguage() }

    static var locale: Locale { Locale(identifier: language) }

    static func string(_ key: String) -> String {
        subtitleLocalizedString(key)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}
