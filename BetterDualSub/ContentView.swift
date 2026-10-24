//
//  ContentView.swift
//  BetterDualSub
//

import SwiftUI
import AppKit
import CoreGraphics
import Combine
import UniformTypeIdentifiers
import Foundation

// MARK: - 2. Outlined subtitle text
/// One track's cue. The outline is drawn as its own pass beneath the letters, so a thick outline frames the glyphs
/// instead of eating into them, and emphasis and colors from the subtitle markup are kept.
struct SubtitleTextView: View, Equatable {
    let rawText: String
    let fontSize: CGFloat
    let style: SubtitleTrackStyle
    var lineMode: SubtitleLineMode = .original

    var body: some View {
        SubtitleTextLabel(runs: SubtitleMarkup.runs(lineMode.apply(to: rawText)), fontSize: fontSize, style: style,
                          fitSingleLine: lineMode == .single)
    }
}

/// The fill and outline layers of a cue, laid out for one width.
struct SubtitleTextLayers {
    var fill = NSAttributedString()
    var outline: NSAttributedString?
    /// Room around the text for the outline and shadow, which spill past the glyphs.
    var inset: CGFloat = 0
    var size: CGSize = .zero
}

private struct SubtitleTextLabel: NSViewRepresentable {
    let runs: [SubtitleTextRun]
    let fontSize: CGFloat
    let style: SubtitleTrackStyle
    /// Shrink the text (down to half size) instead of wrapping when a single line is too wide.
    var fitSingleLine = false

    final class Coordinator { var width: CGFloat? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SubtitleTextNSView { SubtitleTextNSView() }

    func updateNSView(_ view: SubtitleTextNSView, context: Context) {
        view.layers = layers(width: context.coordinator.width)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SubtitleTextNSView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        context.coordinator.width = width
        let layers = layers(width: width)
        nsView.layers = layers
        return layers.size
    }

    private var shadowBlur: CGFloat { style.shadow ? max(2, fontSize * 0.1) : 0 }
    private var shadowDrop: CGFloat { style.shadow ? max(1, fontSize * 0.04) : 0 }

    private func layers(width: CGFloat?) -> SubtitleTextLayers {
        let inset = ceil(style.outlinePixels + shadowBlur + shadowDrop) + 3
        let available = width.map { max(1, $0 - inset * 2) } ?? .greatestFiniteMagnitude
        var size = fontSize
        var layers = makeLayers(size: size)
        if fitSingleLine, width != nil {
            let natural = measure(layers.fill, width: .greatestFiniteMagnitude).width
            if natural > available, natural > 0 {
                size = fontSize * max(0.5, available / natural)
                layers = makeLayers(size: size)
            }
        }
        let bounds = measure(layers.fill, width: available)
        layers.inset = inset
        layers.size = CGSize(width: min(width ?? .greatestFiniteMagnitude, ceil(bounds.width) + inset * 2),
                             height: ceil(bounds.height) + inset * 2)
        return layers
    }

    private func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).size
    }

    private func baseFont(size: CGFloat) -> NSFont {
        let weightOption = FontWeightOption(rawValue: style.weight) ?? .regular
        var descriptor = NSFontDescriptor(fontAttributes: [.family: style.family])
        if weightOption == .bold || weightOption == .heavy { descriptor = descriptor.withSymbolicTraits(.bold) }
        descriptor = descriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weightOption.nsWeight]])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weightOption.nsWeight)
    }

    private func makeLayers(size: CGFloat) -> SubtitleTextLayers {
        let base = baseFont(size: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        let textColor = NSColor(hex: style.textColor)
        let outlineColor = NSColor(hex: style.outlineColor)
        let shadow: NSShadow? = style.shadow ? {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = max(2, size * 0.1)
            shadow.shadowOffset = NSSize(width: 0, height: -max(1, size * 0.04))
            return shadow
        }() : nil
        let hasOutline = style.outlinePixels > 0
        let fill = NSMutableAttributedString()
        let outline = NSMutableAttributedString()
        let manager = NSFontManager.shared
        for run in runs {
            var font = base
            if run.bold, !manager.traits(of: font).contains(.boldFontMask) {
                font = manager.convert(font, toHaveTrait: .boldFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            if run.italic {
                let italic = manager.convert(font, toHaveTrait: .italicFontMask)
                if manager.traits(of: italic).contains(.italicFontMask) {
                    attributes[.font] = italic
                } else {
                    // Most CJK fonts have no italic; slant the regular face instead.
                    attributes[.obliqueness] = 0.18
                }
            }
            outline.append(NSAttributedString(string: run.text, attributes: attributes.merging([
                .foregroundColor: outlineColor, .strokeColor: outlineColor,
                // A positive width strokes without filling; the stroke is centred on the glyph edge and the fill
                // covers its inner half, so twice the outline size leaves exactly that much showing.
                .strokeWidth: size > 0 ? 200 * style.outlinePixels / size : 0,
            ]) { $1 }))
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attributes[.foregroundColor] = run.color.map(NSColor.init(hex:)) ?? textColor
            fill.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        if let shadow {
            let target = hasOutline ? outline : fill
            target.addAttribute(.shadow, value: shadow, range: NSRange(location: 0, length: target.length))
        }
        return SubtitleTextLayers(fill: fill, outline: hasOutline ? outline : nil)
    }
}

/// Draws the outline layer, then the fill on top of it.
final class SubtitleTextNSView: NSView {
    var layers = SubtitleTextLayers() {
        didSet {
            guard !layers.fill.isEqual(to: oldValue.fill) || layers.outline != oldValue.outline
                    || layers.inset != oldValue.inset else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { layers.size }
    /// The drag handle above takes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: layers.inset, dy: layers.inset)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        layers.outline?.draw(with: rect, options: options)
        layers.fill.draw(with: rect, options: options)
    }
}

// MARK: - 3. Transparent SwiftUI overlay
struct ContentView: View {
    @EnvironmentObject var subManager: SubtitleManager
    @AppStorage("primaryFontSize") private var primaryFontSize = SubtitleAppearanceDefaults.fontSize(secondary: false)
    @AppStorage("secondaryFontSize") private var secondaryFontSize = SubtitleAppearanceDefaults.fontSize(secondary: true)
    @AppStorage("primaryFontFamily") private var primaryFontFamily = UserDefaults.standard.string(forKey: "selectedFontFamily") ?? "Helvetica Neue"
    @AppStorage("secondaryFontFamily") private var secondaryFontFamily = "Helvetica Neue"
    @AppStorage("primaryFontWeight") private var primaryFontWeight = UserDefaults.standard.string(forKey: "selectedFontWeight") ?? "Bold"
    @AppStorage("secondaryFontWeight") private var secondaryFontWeight = "Regular"
    @AppStorage("primaryTextColor") private var primaryTextColor = "#FFFFFF"
    @AppStorage("secondaryTextColor") private var secondaryTextColor = "#FFFFFF"
    @AppStorage("primaryOutlineColor") private var primaryOutlineColor = "#000000"
    @AppStorage("secondaryOutlineColor") private var secondaryOutlineColor = "#000000"
    @AppStorage("primaryOutlinePixels") private var primaryOutlinePixels = SubtitleAppearanceDefaults.outlinePixels(secondary: false)
    @AppStorage("secondaryOutlinePixels") private var secondaryOutlinePixels = SubtitleAppearanceDefaults.outlinePixels(secondary: true)
    @AppStorage("primaryLineMode") private var primaryLineMode = SubtitleLineMode.defaultValue.rawValue
    @AppStorage("secondaryLineMode") private var secondaryLineMode = SubtitleLineMode.defaultValue.rawValue
    @AppStorage("primaryShadow") private var primaryShadow = true
    @AppStorage("secondaryShadow") private var secondaryShadow = true
    @AppStorage("backgroundStyle") private var backgroundStyle: String = BackgroundStyleOption.transparent.rawValue
    @AppStorage(SubtitleAppearanceDefaults.backgroundColorKey) private var backgroundColor = SubtitleAppearanceDefaults.backgroundColor
    @AppStorage(SubtitleAppearanceDefaults.backgroundOpacityKey) private var backgroundOpacity = SubtitleAppearanceDefaults.backgroundOpacity
    @AppStorage(SubtitleAppearanceDefaults.backgroundRadiusKey) private var backgroundRadius = SubtitleAppearanceDefaults.backgroundRadius
    @AppStorage("subtitleOffsetX") private var offsetX: Double = 0
    @AppStorage("subtitleOffsetY") private var offsetY: Double = 0
    @AppStorage("showSubtitlePreview") private var showSubtitlePreview = true
    @AppStorage(SubtitleScreenPreferences.displayKey) private var displayID = ""
    @ObservedObject private var overlay = OverlayController.shared

    @State private var tvWindowSize: CGSize = CGSize(width: 800, height: 450)
    @State private var dragTranslation: CGSize = .zero
    @State private var textSize: CGSize = .zero
    @State private var barSize: CGSize = .zero

    private var primaryDisplayText: String {
        if !subManager.currentText.isEmpty { return subManager.currentText }
        if subManager.trackNames.isEmpty && showSubtitlePreview { return "A subtitle preview" }
        // Keep the window visible (and draggable) while there is nothing to show yet.
        guard subManager.secondaryText.isEmpty else { return "" }
        if subManager.trackNames.isEmpty { return AppLocalization.string("overlay.placeholder.idle") }
        return subManager.isPlaying ? "" : AppLocalization.string("overlay.placeholder.waiting")
    }

    private var secondaryDisplayText: String {
        if !subManager.secondaryText.isEmpty { return subManager.secondaryText }
        guard subManager.currentText.isEmpty else { return "" }
        // Keep the empty overlay as one draggable preview. Both styles remain visible on the Appearance page.
        if subManager.trackNames.isEmpty { return "" }
        if subManager.trackNames.count > 1 && !subManager.isPlaying { return AppLocalization.string("overlay.placeholder.secondary") }
        return ""
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            bubble
                .padding(.bottom, tvWindowSize.height * 0.02)
                .offset(x: offsetX * tvWindowSize.width + dragTranslation.width,
                        y: offsetY * tvWindowSize.height + dragTranslation.height)
        }
        .background(Color.clear)
        .onAppear {
            placeOverlay()
            overlay.startHitTesting()
            overlay.hitRects = hitRectsInWindow
            overlay.needsDwell = !hasCue
        }
        .onDisappear {
            overlay.stopHitTesting()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in placeOverlay() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in placeOverlay() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in placeOverlay() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in placeOverlay() }
        .onReceive(NotificationCenter.default.publisher(for: .subtitleDisplayChanged)) { _ in
            placeOverlay()
            overlay.refreshHitTesting()
        }
        .onChange(of: hitRectsInWindow) { _, rects in overlay.hitRects = rects }
        .onChange(of: hasCue) { _, value in overlay.needsDwell = !value }
        .onChange(of: displayID) { _, _ in placeOverlay() }
        .onReceive(NotificationCenter.default.publisher(for: .adjustSubtitleDelay)) { note in
            guard let track = note.userInfo?["track"] as? String, let delta = note.userInfo?["delta"] as? Int else { return }
            subManager.adjustDelay(track: track, delta: delta)
        }
        .onReceive(NotificationCenter.default.publisher(for: .manualPlaybackCommand)) { note in
            guard let raw = note.userInfo?["action"] as? Int, let action = SubtitleShortcutAction(rawValue: raw),
                  !subManager.trackNames.isEmpty else { return }
            switch action {
            case .manualPlayPause: subManager.togglePlay()
            case .manualBack: subManager.seek(byMs: -10_000)
            case .manualForward: subManager.seek(byMs: 10_000)
            default: break
            }
        }
    }

    /// A real cue (not a placeholder) is on screen.
    private var hasCue: Bool { !subManager.currentText.isEmpty || !subManager.secondaryText.isEmpty }

    /// Areas that must take the mouse, in window coordinates (top-left origin): the visible subtitle box and, while shown,
    /// the control bar. Everything else (gaps, the toast, empty corners) stays click-through.
    private var hitRectsInWindow: [CGRect] {
        guard textSize != .zero else { return [] }
        let width = tvWindowSize.width, height = tvWindowSize.height
        let centerX = width / 2 + offsetX * width + dragTranslation.width
        let bottom = height - height * 0.02 + offsetY * height + dragTranslation.height
        var rects = [CGRect(x: centerX - textSize.width / 2, y: bottom - textSize.height, width: textSize.width, height: textSize.height)]
        if barSize != .zero {
            rects.append(CGRect(x: centerX - barSize.width / 2, y: bottom - textSize.height - 6 - barSize.height,
                                width: barSize.width, height: barSize.height))
        }
        return rects
    }

    /// Control bar (manual mode, on hover) above the subtitle text; the whole stack is the hover region.
    private var bubble: some View {
        let showBar = !subManager.trackNames.isEmpty && (overlay.isHovering || overlay.isDragging || overlay.isEditing || overlay.isAligning)
        return VStack(spacing: 6) {
            if showBar {
                ManualControlBar(manager: subManager)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { barSize = proxy.size }
                            .onChange(of: proxy.size) { _, size in barSize = size }
                            .onDisappear { barSize = .zero }
                    })
            }
            textBubble
        }
        .overlay(alignment: .top) {
            if let toast = subManager.delayToast {
                Text(verbatim: toast)
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular.tint(.black.opacity(0.3)), in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .fixedSize()
                    .offset(y: -40)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: subManager.delayToast)
    }

    private var textBubble: some View {
        let hasText = !primaryDisplayText.isEmpty || !secondaryDisplayText.isEmpty
        // With no cue on screen, keep an empty box about the size of the usual subtitle so the background (and hover target) stay put.
        let primarySize = max(SubtitleAppearanceLimits.minimumFontSize, primaryFontSize)
        let secondarySize = max(SubtitleAppearanceLimits.minimumFontSize, secondaryFontSize)
        let emptyHeight = (primarySize + (subManager.trackNames.count > 1 ? secondarySize + 5 : 0)) * 1.4 + 16
        return VStack(spacing: 5) {
            if !primaryDisplayText.isEmpty {
                SubtitleTextView(rawText: primaryDisplayText,
                               fontSize: primarySize, style: primaryStyle,
                               lineMode: SubtitleLineMode(rawValue: primaryLineMode) ?? .original)
                    .equatable()
            }
            if !secondaryDisplayText.isEmpty {
                SubtitleTextView(rawText: secondaryDisplayText,
                               fontSize: secondarySize, style: secondaryStyle,
                               lineMode: SubtitleLineMode(rawValue: secondaryLineMode) ?? .original)
                    .equatable()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minWidth: hasText ? 0 : tvWindowSize.width * 0.4, minHeight: hasText ? 0 : emptyHeight)
        .background(
            SubtitleBackgroundView(style: backgroundStyle, colorHex: backgroundColor,
                                   opacity: backgroundOpacity, radius: backgroundRadius)
        )
        // Measured before the max-width frame below, which is much wider than the visible box.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { textSize = proxy.size }
                .onChange(of: proxy.size) { _, size in textSize = size }
        })
        .overlay {
            do {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(overlay.isHovering || overlay.isDragging ? 0.7 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                OverlayDragHandle(
                    onDrag: { dragTranslation = $0; overlay.isDragging = true },
                    onEnd: {
                        offsetX = min(0.45, max(-0.45, offsetX + dragTranslation.width / max(1, tvWindowSize.width)))
                        offsetY = min(0.02, max(-0.95, offsetY + dragTranslation.height / max(1, tvWindowSize.height)))
                        dragTranslation = .zero
                        overlay.isDragging = false
                    },
                    onHide: { OverlayController.setVisible(false) },
                    onReset: { OverlayController.resetPosition() }
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if overlay.isHovering && !overlay.isDragging {
                Button { OverlayController.setVisible(false) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: Circle())
                        .environment(\.colorScheme, .dark)
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
        // Constrain the width last so the border, drag area and close button hug the visible subtitle box.
        .frame(maxWidth: tvWindowSize.width * 0.9)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var primaryStyle: SubtitleTrackStyle {
        SubtitleTrackStyle(family: primaryFontFamily, weight: primaryFontWeight,
                           textColor: primaryTextColor, outlineColor: primaryOutlineColor, outlinePixels: primaryOutlinePixels,
                           shadow: primaryShadow)
    }

    private var secondaryStyle: SubtitleTrackStyle {
        SubtitleTrackStyle(family: secondaryFontFamily, weight: secondaryFontWeight,
                           textColor: secondaryTextColor, outlineColor: secondaryOutlineColor, outlinePixels: secondaryOutlinePixels,
                           shadow: secondaryShadow)
    }
    
    // MARK: - Overlay placement
    /// Uses the chosen screen (or the current main screen) and remembers each display's free placement.
    private func placeOverlay() {
        guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == OverlayPanel.identifierValue }) else { return }
        guard OverlayController.isVisible else {
            if window.isVisible { window.orderOut(nil) }
            return
        }
        guard let screen = SubtitleScreenPreferences.selectedScreen else { return }
        SubtitleScreenPreferences.prepare(screen)
        let targetFrame = screen.visibleFrame
        if tvWindowSize != targetFrame.size { tvWindowSize = targetFrame.size }
        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
        if window.level != .mainMenu { window.level = .mainMenu }
        if window.frame != targetFrame { window.setFrame(targetFrame, display: true, animate: false) }
        if !window.isVisible { window.orderFrontRegardless() }
    }

}

// MARK: - 4. Blur effect background helper
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow // Use a semantic material instead of .dark
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        
        // Force the effect to render in the dark tone (Vibrant Dark)
        visualEffectView.appearance = NSAppearance(named: .vibrantDark)
        
        return visualEffectView
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.appearance = NSAppearance(named: .vibrantDark)
    }
}

// Identify the overlay explicitly so docking never moves the download window.
/// Borderless, click-through-by-default panel for the subtitles. Non-activating, so clicking the subtitles
/// does not bring the app's other windows (the control center) to the front.
final class OverlayPanel: NSPanel {
    static let identifierValue = "subtitle-overlay"

    init() {
        super.init(contentRect: NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 450),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier(Self.identifierValue)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .mainMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        contentView = NSHostingView(rootView: OverlayRootView())
    }

    /// Only while a text field is being edited, so clicking the subtitles never steals keyboard focus from the player.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

private struct OverlayRootView: View {
    @AppStorage(AppLocalization.languagePreferenceKey) private var language = AppLocalization.defaultLanguage

    var body: some View {
        ContentView()
            .environmentObject(SubtitleManager.shared)
            .environment(\.locale, Locale(identifier: language))
    }
}

// MARK: - 5. Free-position overlay support
/// Shared state for the draggable subtitle window.
@MainActor
final class OverlayController: ObservableObject {
    static let shared = OverlayController()
    nonisolated static let visibleKey = "showSubtitleWindow"

    @Published var isHovering = false
    @Published var isDragging = false
    /// A text field in the control bar has focus; keep the bar open and the panel interactive.
    @Published var isEditing = false
    /// The line-alignment panel is open: the bar stays up until it is closed, but only takes the mouse while pointed at.
    @Published var isAligning = false
    var hitRects: [CGRect] = []
    /// With no real cue on screen the subtitle box is just an empty frame; only capture the mouse once the pointer rests in it.
    var needsDwell = false
    private var enteredAt: TimeInterval?
    private var timer: Timer?
    private var lastInside: TimeInterval = -.infinity

    nonisolated static var isVisible: Bool {
        UserDefaults.standard.object(forKey: visibleKey) as? Bool ?? true
    }

    nonisolated static let lockedKey = "subtitleOverlayLocked"

    /// While locked the overlay never takes the mouse, so everything under it stays usable.
    nonisolated static var isLocked: Bool { UserDefaults.standard.bool(forKey: lockedKey) }

    static func setLocked(_ locked: Bool) {
        UserDefaults.standard.set(locked, forKey: lockedKey)
        NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil)
        shared.isHovering = false
        if locked { shared.isAligning = false }
        SubtitleManager.shared.showToast(AppLocalization.string(locked ? "overlay.locked.toast" : "overlay.unlocked.toast"))
    }

    static func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: visibleKey)
        NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil)
    }

    static func resetPosition() {
        UserDefaults.standard.set(0.0, forKey: "subtitleOffsetX")
        UserDefaults.standard.set(0.0, forKey: "subtitleOffsetY")
    }

    /// The overlay ignores the mouse so TV.app stays clickable; it only accepts clicks while the pointer is over the subtitles.
    func refreshHitTesting() {
        if Self.isVisible && !Self.isLocked { startHitTesting() } else { stopHitTesting() }
    }

    func startHitTesting() {
        guard Self.isVisible, !Self.isLocked, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHitTesting() }
        }
    }

    func stopHitTesting() {
        timer?.invalidate()
        timer = nil
        isHovering = false
        isEditing = false
        isAligning = false
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == OverlayPanel.identifierValue }) {
            window.ignoresMouseEvents = true
        }
    }

    private func updateHitTesting() {
        guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "subtitle-overlay" }),
              window.isVisible else {
            if isHovering { isHovering = false }
            return
        }
        if Self.isLocked {
            if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
            if isHovering { isHovering = false }
            if isEditing { isEditing = false }
            if isAligning { isAligning = false }
            return
        }
        // Clicking another app while a bar field has focus leaves its field editor in place, so editing never ends on
        // its own and the panel (which covers the whole screen) would keep taking every click. Finish the edit instead.
        if isEditing, !window.isKeyWindow {
            window.makeFirstResponder(nil)
            isEditing = false
        }
        if NSEvent.pressedMouseButtons != 0 { return }
        let mouse = NSEvent.mouseLocation
        let inside = hitRects.contains { rect in
            let r = rect.insetBy(dx: -4, dy: -4)
            return CGRect(x: window.frame.minX + r.minX, y: window.frame.maxY - r.maxY, width: r.width, height: r.height).contains(mouse)
        }
        let now = ProcessInfo.processInfo.systemUptime
        var active = inside
        if inside, needsDwell, !isHovering, !isEditing, !isAligning {
            if enteredAt == nil { enteredAt = now }
            active = now - (enteredAt ?? now) >= 0.35
        } else if !inside {
            enteredAt = nil
        }
        if active { lastInside = now }
        // Hold the hover state briefly so the pointer can cross the gap between the bar and the subtitles.
        let hovering = active || isEditing || (isHovering && now - lastInside < 0.4)
        if window.ignoresMouseEvents == hovering { window.ignoresMouseEvents = !hovering }
        if isHovering != hovering { isHovering = hovering }
    }
}

/// Transparent layer over the subtitles that handles dragging and the context menu.
struct OverlayDragHandle: NSViewRepresentable {
    var onDrag: (CGSize) -> Void
    var onEnd: () -> Void
    var onHide: () -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag; view.onEnd = onEnd; view.onHide = onHide; view.onReset = onReset
    }

    final class HandleView: NSView {
        var onDrag: (CGSize) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onHide: () -> Void = {}
        var onReset: () -> Void = {}
        private var start = NSPoint.zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation }
        override func mouseDragged(with event: NSEvent) {
            let point = NSEvent.mouseLocation
            onDrag(CGSize(width: point.x - start.x, height: start.y - point.y))
        }
        override func mouseUp(with event: NSEvent) { onEnd() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            let hide = NSMenuItem(title: AppLocalization.string("overlay.hide"), action: #selector(hide), keyEquivalent: "")
            let reset = NSMenuItem(title: AppLocalization.string("appearance.window.reset"), action: #selector(reset), keyEquivalent: "")
            let lock = NSMenuItem(title: AppLocalization.string("overlay.lock"), action: #selector(lockOverlay), keyEquivalent: "")
            lock.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
            lock.target = self
            let appearance = NSMenuItem(title: AppLocalization.string("overlay.openAppearance"), action: #selector(openAppearance), keyEquivalent: "")
            appearance.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
            hide.target = self; reset.target = self; appearance.target = self
            menu.addItem(appearance)
            menu.addItem(lock)
            menu.addItem(.separator())
            menu.addItem(reset)
            menu.addItem(hide)
            return menu
        }
        @objc private func openAppearance() {
            AppDelegate.shared?.showControlCenter(page: "appearance")
        }
        @objc private func lockOverlay() { OverlayController.setLocked(true) }
        @objc private func hide() { onHide() }
        @objc private func reset() { onReset() }
    }
}
