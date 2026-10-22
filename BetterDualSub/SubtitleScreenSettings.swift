import SwiftUI
import AppKit
import CoreGraphics

/// Keeps free placement, while allowing a stable display choice and a separate layout on each display.
@MainActor
enum SubtitleScreenPreferences {
    static let displayKey = "subtitleDisplayID"
    private static let layoutsKey = "subtitleScreenLayouts"
    private static let layoutKeys = ["subtitleOffsetX", "subtitleOffsetY", "primaryFontSize", "secondaryFontSize"]
    private static var activeID: String?

    static func id(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return screen.localizedName }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return number.stringValue
    }

    static var selectedScreen: NSScreen? {
        let preferred = UserDefaults.standard.string(forKey: displayKey) ?? ""
        return NSScreen.screens.first { id($0) == preferred } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func acceptRestoredSettings() {
        let preferred = UserDefaults.standard.string(forKey: displayKey) ?? ""
        activeID = NSScreen.screens.first(where: { id($0) == preferred }).map(id)
    }

    static func prepare(_ screen: NSScreen) {
        let defaults = UserDefaults.standard
        let nextID = id(screen)
        saveCurrentLayout()
        let layouts = defaults.dictionary(forKey: layoutsKey) as? [String: [Double]] ?? [:]
        guard activeID != nextID else { return }
        let hadDisplay = activeID != nil
        activeID = nextID
        if let layout = layouts[nextID], layout.count == layoutKeys.count, layout.allSatisfy(\.isFinite) {
            for (key, value) in zip(layoutKeys, layout) { defaults.set(value, forKey: key) }
        } else if hadDisplay {
            defaults.set(0.0, forKey: layoutKeys[0])
            defaults.set(0.0, forKey: layoutKeys[1])
        }
    }

    static func saveCurrentLayout() {
        guard let activeID else { return }
        let defaults = UserDefaults.standard
        var layouts = defaults.dictionary(forKey: layoutsKey) as? [String: [Double]] ?? [:]
        let current = [defaults.double(forKey: layoutKeys[0]), defaults.double(forKey: layoutKeys[1]),
                       SubtitleAppearanceDefaults.fontSize(secondary: false), SubtitleAppearanceDefaults.fontSize(secondary: true)]
        if layouts[activeID] != current {
            layouts[activeID] = current
            defaults.set(layouts, forKey: layoutsKey)
        }
    }
}

struct SubtitleScreenSettings: View {
    @AppStorage(SubtitleScreenPreferences.displayKey) private var displayID = ""
    @State private var screens = NSScreen.screens

    var body: some View {
        SettingsCard(titleKey: "screen.title") {
            Picker("screen.choose", selection: $displayID) {
                Text("screen.auto").tag("")
                ForEach(screens, id: \.self) { screen in
                    Text(verbatim: screen.localizedName).tag(SubtitleScreenPreferences.id(screen))
                }
                if !displayID.isEmpty, !screens.contains(where: { SubtitleScreenPreferences.id($0) == displayID }) {
                    Text("screen.disconnected").tag(displayID)
                }
            }
            SettingsHint(key: "screen.help")
            if let screen = SubtitleScreenPreferences.selectedScreen {
                Text(AppLocalization.format("screen.current", screen.localizedName)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onChange(of: displayID) { _, _ in
            NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil)
        }
    }
}
