import SwiftUI
import AppKit

enum SubtitleAppearanceLimits {
    static let minimumFontSize: CGFloat = 12
    static let fontSizeRatio: ClosedRange<Double> = 0.008...0.08
    static let outlineWidth: ClosedRange<Double> = 0...24
}

/// Factory defaults for everything on the appearance page, shared by the editors and the reset buttons.
enum SubtitleAppearanceDefaults {
    static let backgroundColorKey = "customBackgroundColor"
    static let backgroundOpacityKey = "customBackgroundOpacity"
    static let backgroundRadiusKey = "customBackgroundRadius"
    static let backgroundColor = "#000000"
    static let backgroundOpacity = 0.5
    static let backgroundRadius = 8.0

    static func trackValues(secondary: Bool) -> [String: Any] {
        let prefix = secondary ? "secondary" : "primary"
        return [prefix + "FontFamily": "Helvetica Neue", prefix + "FontWeight": secondary ? "Regular" : "Bold",
                prefix + "FontSizeRatio": secondary ? 0.018 : 0.02, prefix + "TextColor": "#FFFFFF",
                prefix + "OutlineColor": "#000000", prefix + "OutlineWidth": 3.5,
                prefix + "LineMode": SubtitleLineMode.defaultValue.rawValue]
    }

    static var backgroundValues: [String: Any] {
        ["backgroundStyle": BackgroundStyleOption.transparent.rawValue, backgroundColorKey: backgroundColor,
         backgroundOpacityKey: backgroundOpacity, backgroundRadiusKey: backgroundRadius]
    }

    static func apply(_ values: [String: Any]) {
        for (key, value) in values { UserDefaults.standard.set(value, forKey: key) }
        NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil)
    }
}

/// Backdrop behind the subtitle text; also used by the preview so both always match.
struct SubtitleBackgroundView: View {
    let style: String
    let colorHex: String
    let opacity: Double
    let radius: Double

    var body: some View {
        switch BackgroundStyleOption(rawValue: style) ?? .transparent {
        case .transparent:
            EmptyView()
        case .blur:
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                Color.black.opacity(0.1)
            }
            .cornerRadius(8)
        case .custom:
            RoundedRectangle(cornerRadius: radius).fill(Color(hex: colorHex).opacity(opacity))
        }
    }
}

struct SubtitleTrackStyle {
    let family: String
    let weight: String
    let textColor: String
    let outlineColor: String
    let outlineWidth: CGFloat
}

struct SubtitleAppearanceView: View {
    var body: some View {
        SettingsPage(descriptionKey: "appearance.description") {
            SubtitlePreviewCard()
            SubtitleWindowCard()
            SubtitleTrackStyleEditor(secondary: false)
            SubtitleTrackStyleEditor(secondary: true)
            HStack {
                Spacer()
                Button("appearance.resetAll") {
                    SubtitleAppearanceDefaults.apply(SubtitleAppearanceDefaults.trackValues(secondary: false)
                        .merging(SubtitleAppearanceDefaults.trackValues(secondary: true)) { $1 }
                        .merging(SubtitleAppearanceDefaults.backgroundValues) { $1 })
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SubtitleWindowCard: View {
    @AppStorage(OverlayController.visibleKey) private var showWindow = true
    @AppStorage(OverlayController.lockedKey) private var locked = false
    @AppStorage("backgroundStyle") private var backgroundStyle = BackgroundStyleOption.transparent.rawValue
    @AppStorage(SubtitleAppearanceDefaults.backgroundColorKey) private var backgroundColor = SubtitleAppearanceDefaults.backgroundColor
    @AppStorage(SubtitleAppearanceDefaults.backgroundOpacityKey) private var backgroundOpacity = SubtitleAppearanceDefaults.backgroundOpacity
    @AppStorage(SubtitleAppearanceDefaults.backgroundRadiusKey) private var backgroundRadius = SubtitleAppearanceDefaults.backgroundRadius

    var body: some View {
        SettingsCard(titleKey: "appearance.window.title") {
            SettingsRow(symbol: "macwindow", tint: .blue, titleKey: "appearance.window.show", subtitleKey: "appearance.window.help") {
                Toggle("appearance.window.show", isOn: $showWindow).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            SettingsRow(symbol: "lock", tint: .orange, titleKey: "appearance.window.lock", subtitleKey: "appearance.window.lock.help") {
                Toggle("appearance.window.lock", isOn: $locked).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            SettingsRow(symbol: "rectangle.dashed", tint: .purple, titleKey: "menu.background.title") {
                Picker("menu.background.title", selection: $backgroundStyle) {
                    Text("menu.background.transparent").tag(BackgroundStyleOption.transparent.rawValue)
                    Text("menu.background.blur").tag(BackgroundStyleOption.blur.rawValue)
                    Text("menu.background.custom").tag(BackgroundStyleOption.custom.rawValue)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if backgroundStyle == BackgroundStyleOption.custom.rawValue {
                Divider()
                ColorPicker("appearance.background.color", selection: Binding(
                    get: { Color(hex: backgroundColor) }, set: { backgroundColor = $0.hexString }), supportsOpacity: false)
                HStack {
                    Text("appearance.background.opacity")
                    Slider(value: $backgroundOpacity, in: 0...1, step: 0.05)
                    Text(backgroundOpacity.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().frame(width: 54, alignment: .trailing)
                }
                HStack {
                    Text("appearance.background.radius")
                    Slider(value: $backgroundRadius, in: 0...24, step: 1)
                    Text("\(Int(backgroundRadius)) pt").monospacedDigit().frame(width: 54, alignment: .trailing)
                }
            }
            Divider()
            HStack {
                Button("appearance.background.reset") { SubtitleAppearanceDefaults.apply(SubtitleAppearanceDefaults.backgroundValues) }
                Spacer()
                Button("appearance.window.reset") { OverlayController.resetPosition() }
            }
        }
        .onChange(of: showWindow) { _, _ in NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil) }
        .onChange(of: locked) { _, _ in NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil) }
        .onChange(of: backgroundStyle) { _, _ in NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil) }
    }
}

private struct SubtitlePreviewCard: View {
    @AppStorage("showSubtitlePreview") private var showSubtitlePreview = true
    @AppStorage("primaryFontSizeRatio") private var primaryFontSizeRatio = UserDefaults.standard.object(forKey: "fontSizeRatio") as? Double ?? 0.02
    @AppStorage("secondaryFontSizeRatio") private var secondaryFontSizeRatio = 0.018
    @AppStorage("primaryFontFamily") private var primaryFamily = UserDefaults.standard.string(forKey: "selectedFontFamily") ?? "Helvetica Neue"
    @AppStorage("secondaryFontFamily") private var secondaryFamily = "Helvetica Neue"
    @AppStorage("primaryFontWeight") private var primaryWeight = UserDefaults.standard.string(forKey: "selectedFontWeight") ?? "Bold"
    @AppStorage("secondaryFontWeight") private var secondaryWeight = "Regular"
    @AppStorage("primaryTextColor") private var primaryTextColor = "#FFFFFF"
    @AppStorage("secondaryTextColor") private var secondaryTextColor = "#FFFFFF"
    @AppStorage("primaryOutlineColor") private var primaryOutlineColor = "#000000"
    @AppStorage("secondaryOutlineColor") private var secondaryOutlineColor = "#000000"
    @AppStorage("primaryOutlineWidth") private var primaryOutlineWidth = 3.5
    @AppStorage("secondaryOutlineWidth") private var secondaryOutlineWidth = 3.5
    @AppStorage("primaryLineMode") private var primaryLineMode = SubtitleLineMode.defaultValue.rawValue
    @AppStorage("secondaryLineMode") private var secondaryLineMode = SubtitleLineMode.defaultValue.rawValue
    @AppStorage("backgroundStyle") private var backgroundStyle = BackgroundStyleOption.transparent.rawValue
    @AppStorage(SubtitleAppearanceDefaults.backgroundColorKey) private var backgroundColor = SubtitleAppearanceDefaults.backgroundColor
    @AppStorage(SubtitleAppearanceDefaults.backgroundOpacityKey) private var backgroundOpacity = SubtitleAppearanceDefaults.backgroundOpacity
    @AppStorage(SubtitleAppearanceDefaults.backgroundRadiusKey) private var backgroundRadius = SubtitleAppearanceDefaults.backgroundRadius

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("appearance.preview.heading", systemImage: "captions.bubble").font(.headline)
                Spacer()
                Text("appearance.preview.title").font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(
                    LinearGradient(colors: [Color(white: 0.30), Color(white: 0.16)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                GeometryReader { geometry in
                    VStack(spacing: 12) {
                        HTMLStrokeText(rawText: "A subtitle preview",
                                       fontSize: max(SubtitleAppearanceLimits.minimumFontSize, geometry.size.width * primaryFontSizeRatio), style: primaryStyle,
                                       lineMode: SubtitleLineMode(rawValue: primaryLineMode) ?? .original)
                        HTMLStrokeText(rawText: AppLocalization.string("overlay.placeholder.secondary"),
                                       fontSize: max(SubtitleAppearanceLimits.minimumFontSize, geometry.size.width * secondaryFontSizeRatio), style: secondaryStyle,
                                       lineMode: SubtitleLineMode(rawValue: secondaryLineMode) ?? .original)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(SubtitleBackgroundView(style: backgroundStyle, colorHex: backgroundColor,
                                                       opacity: backgroundOpacity, radius: backgroundRadius))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
                }
            }
            .frame(height: 190)
            Toggle("appearance.preview.showWhenEmpty", isOn: $showSubtitlePreview)
            HStack(alignment: .center) {
                Text("appearance.preview.hint")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("menu.openFile") {
                    NotificationCenter.default.post(name: .navigateToControlCenter, object: nil, userInfo: ["page": "localFile"])
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardBackground()
    }

    private var primaryStyle: SubtitleTrackStyle {
        SubtitleTrackStyle(family: primaryFamily, weight: primaryWeight,
                           textColor: primaryTextColor, outlineColor: primaryOutlineColor, outlineWidth: primaryOutlineWidth)
    }

    private var secondaryStyle: SubtitleTrackStyle {
        SubtitleTrackStyle(family: secondaryFamily, weight: secondaryWeight,
                           textColor: secondaryTextColor, outlineColor: secondaryOutlineColor, outlineWidth: secondaryOutlineWidth)
    }
}

private struct SubtitleTrackStyleEditor: View {
    private static let installedFontFamilies = NSFontManager.shared.availableFontFamilies.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }

    let secondary: Bool
    @AppStorage private var family: String
    @AppStorage private var weight: String
    @AppStorage private var size: Double
    @AppStorage private var textHex: String
    @AppStorage private var outlineHex: String
    @AppStorage private var outlineWidth: Double
    @AppStorage private var lineMode: String

    init(secondary: Bool) {
        self.secondary = secondary
        let prefix = secondary ? "secondary" : "primary"
        let defaults = UserDefaults.standard
        _family = AppStorage(wrappedValue: defaults.string(forKey: prefix + "FontFamily") ?? (secondary ? "Helvetica Neue" : defaults.string(forKey: "selectedFontFamily") ?? "Helvetica Neue"), prefix + "FontFamily")
        _weight = AppStorage(wrappedValue: defaults.string(forKey: prefix + "FontWeight") ?? (secondary ? "Regular" : defaults.string(forKey: "selectedFontWeight") ?? "Bold"), prefix + "FontWeight")
        _size = AppStorage(wrappedValue: defaults.object(forKey: prefix + "FontSizeRatio") as? Double ?? (secondary ? 0.018 : defaults.object(forKey: "fontSizeRatio") as? Double ?? 0.02), prefix + "FontSizeRatio")
        _textHex = AppStorage(wrappedValue: defaults.string(forKey: prefix + "TextColor") ?? "#FFFFFF", prefix + "TextColor")
        _outlineHex = AppStorage(wrappedValue: defaults.string(forKey: prefix + "OutlineColor") ?? "#000000", prefix + "OutlineColor")
        _outlineWidth = AppStorage(wrappedValue: defaults.object(forKey: prefix + "OutlineWidth") as? Double ?? 3.5, prefix + "OutlineWidth")
        _lineMode = AppStorage(wrappedValue: SubtitleLineMode.defaultValue.rawValue, prefix + "LineMode")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(LocalizedStringKey(secondary ? "appearance.track.secondary" : "appearance.track.primary"))
                    .font(.headline)
                Spacer()
                Button("appearance.track.reset") {
                    SubtitleAppearanceDefaults.apply(SubtitleAppearanceDefaults.trackValues(secondary: secondary))
                }
            }
            Picker("appearance.fontFamily", selection: $family) {
                ForEach(fontFamilies, id: \.self) { fontFamily in
                    Text(fontFamily)
                        .font(.custom(fontFamily, size: 14))
                        .tag(fontFamily)
                }
            }
            .pickerStyle(.menu)
            Picker("appearance.weight.title", selection: $weight) {
                ForEach(FontWeightOption.allCases) { option in Text(LocalizedStringKey(option.titleKey)).tag(option.rawValue) }
            }
            HStack {
                Text("appearance.size")
                Slider(value: $size, in: SubtitleAppearanceLimits.fontSizeRatio, step: 0.001)
                Text(size.formatted(.percent.precision(.fractionLength(0...1))))
                    .monospacedDigit().frame(width: 54, alignment: .trailing)
            }
            Picker("appearance.lineMode", selection: $lineMode) {
                Text("appearance.lineMode.original").tag(SubtitleLineMode.original.rawValue)
                Text("appearance.lineMode.single").tag(SubtitleLineMode.single.rawValue)
                Text("appearance.lineMode.double").tag(SubtitleLineMode.double.rawValue)
            }
            .pickerStyle(.segmented)
            ColorPicker("appearance.textColor", selection: colorBinding($textHex), supportsOpacity: false)
            ColorPicker("appearance.outlineColor", selection: colorBinding($outlineHex), supportsOpacity: false)
            HStack {
                Text("appearance.outlineWidth")
                Slider(value: $outlineWidth, in: SubtitleAppearanceLimits.outlineWidth, step: 0.5)
                Text("\(outlineWidth.formatted(.number.precision(.fractionLength(0...1))))%")
                    .monospacedDigit().frame(width: 60, alignment: .trailing)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardBackground()
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hex: hex.wrappedValue) }, set: { hex.wrappedValue = $0.hexString })
    }

    private var fontFamilies: [String] {
        guard !Self.installedFontFamilies.contains(family) else { return Self.installedFontFamilies }
        return ([family] + Self.installedFontFamilies).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
}

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0xFFFFFF
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: 1)
    }

    var hexString: String {
        let rgb = NSColor(self).usingColorSpace(.deviceRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

extension NSColor {
    convenience init(hex: String) {
        let color = Color(hex: hex)
        self.init(color)
    }
}
