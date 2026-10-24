//
//  ManualControlBar.swift
//  BetterDualSub
//

import SwiftUI
import AppKit

/// Playback controls shown over the subtitles while the manual clock is driving them.
struct ManualControlBar: View {
    @ObservedObject var manager: SubtitleManager
    @ObservedObject private var overlay = OverlayController.shared
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var resumeAfterScrub = false
    /// Tip of the control under the pointer. System tooltips only appear in the active app, and the player is the
    /// active app while the subtitles are in use, so the bar draws its own.
    @State private var tip: String?

    private var hasSecondTrack: Bool { manager.trackNames.count > 1 }

    var body: some View {
        VStack(spacing: 6) {
            if overlay.isAligning {
                OverlayAlignPanel(manager: manager, tip: $tip)
                Divider().overlay(Color.white.opacity(0.2))
            }
            HStack(spacing: 8) {
                Button { manager.seek(byMs: -10_000) } label: { Image(systemName: "gobackward.10") }
                    .barTip("bar.back10", $tip)
                Button { manager.togglePlay() } label: {
                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .barTip(manager.isPlaying ? "bar.pause" : "bar.play", $tip)
                Button { manager.seek(byMs: 10_000) } label: { Image(systemName: "goforward.10") }
                    .barTip("bar.forward10", $tip)
                Text(Self.format(scrubbing ? Int(scrubValue) : manager.positionMs))
                    .monospacedDigit().frame(minWidth: 52, alignment: .trailing)
                Slider(value: Binding(get: { scrubbing ? scrubValue : Double(manager.positionMs) },
                                      set: { scrubValue = $0; if manager.activeSource == .manual { manager.seek(toMs: Int($0)) } }),
                       in: 0...Double(max(1, manager.durationMs))) { editing in
                    if editing {
                        scrubbing = true
                        scrubValue = Double(manager.positionMs)
                        // The manual clock follows the drag; a real player is only told where to go on release.
                        resumeAfterScrub = manager.activeSource == .manual && manager.beginScrub()
                    } else {
                        scrubbing = false
                        if manager.activeSource == .tv { manager.seek(toMs: Int(scrubValue)) }
                        manager.endScrub(resume: resumeAfterScrub)
                    }
                }
                .controlSize(.small)
                .barTip("bar.seek", $tip)
                Text(Self.format(manager.durationMs)).monospacedDigit().foregroundStyle(.secondary)
                if manager.activeSource == .manual {
                Menu {
                    ForEach(SubtitleManager.manualSpeeds, id: \.self) { speed in
                        Button { manager.setManualSpeed(speed) } label: {
                            Text(verbatim: Self.speedLabel(speed) + (speed == manager.manualSpeed ? " ✓" : ""))
                        }
                    }
                } label: { Text(verbatim: Self.speedLabel(manager.manualSpeed)).monospacedDigit() }
                .barMenuStyle()
                .barTip("bar.manualSpeed", $tip)
                } else {
                    Text(verbatim: Self.speedLabel(manager.playbackSpeed)).monospacedDigit().fixedSize()
                        .barTip("sync.playerRate.help", $tip)
                }
                Menu {
                    Button("sync.mode.auto") { manager.setSyncMode(.auto) }
                    Button("sync.mode.manual") { manager.setSyncMode(.manual) }
                } label: { Image(systemName: "gearshape") }
                .barMenuStyle()
                .barTip("sync.mode.title", $tip)
            }
            HStack(spacing: 14) {
                SyncStatusIndicator(status: manager.syncStatus)
                    .barTip(text: manager.syncStatus.help ?? manager.syncStatus.title, $tip)
                offsetControl(title: hasSecondTrack && manager.linkSecondaryDelay ? "manual.offset.both" : "manual.offset.primary",
                              value: manager.timeOffsetMs, track: "primary")
                if hasSecondTrack {
                    Button { manager.setLink(!manager.linkSecondaryDelay) } label: {
                        Image(systemName: "link").opacity(manager.linkSecondaryDelay ? 1 : 0.4)
                    }
                    .barTip("manual.offset.linkHint", $tip)
                    if !manager.linkSecondaryDelay {
                        offsetControl(title: "manual.offset.secondary", value: manager.secondaryOffsetMs, track: "secondary")
                    }
                }
                Button { overlay.isAligning.toggle() } label: {
                    Image(systemName: "scope").foregroundStyle(overlay.isAligning ? Color.accentColor : .white)
                }
                .barTip("align.open", $tip)
                Button { OverlayController.setLocked(true) } label: { Image(systemName: "lock.open") }
                    .barTip("overlay.lock", $tip)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        // Two unlinked tracks each need their own delay controls.
        .frame(width: hasSecondTrack && !manager.linkSecondaryDelay ? 720 : 560)
        // Darkened glass keeps the white controls readable over bright video.
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Above the bar, growing upward from a zero-height strip on its top edge, so it never covers a control.
        .overlay(alignment: .top) {
            Color.clear.frame(height: 0)
                .overlay(alignment: .bottom) {
                    if let tip {
                        Text(verbatim: tip)
                            .font(.system(size: 11)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .glassEffect(.regular.tint(.black.opacity(0.4)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: 460)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 6)
                    }
                }
                .allowsHitTesting(false)
        }
        .onChange(of: overlay.isHovering) { _, hovering in if !hovering { tip = nil } }
        // The bar always sits over video, so its glass and menus use the dark variant whatever the system appearance.
        .environment(\.colorScheme, .dark)
    }

    private func offsetControl(title: LocalizedStringKey, value: Int, track: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            stepButton(track: track, delta: -SubtitleDelayStep.largeMilliseconds, symbol: "chevron.backward.2")
            stepButton(track: track, delta: -SubtitleDelayStep.milliseconds, symbol: "minus.circle")
            DelayField(value: value) { manager.setDelay(track: track, ms: $0) }
                .frame(width: 64, height: 20)
                .barTip("bar.delay.field", $tip)
            Text("ms").foregroundStyle(.secondary).fixedSize()
            stepButton(track: track, delta: SubtitleDelayStep.milliseconds, symbol: "plus.circle")
            stepButton(track: track, delta: SubtitleDelayStep.largeMilliseconds, symbol: "chevron.forward.2")
            Button { manager.adjustDelay(track: track, delta: Int.min) } label: { Image(systemName: "arrow.counterclockwise") }
                .barTip("bar.delay.reset", $tip)
        }
    }

    private func stepButton(track: String, delta: Int, symbol: String) -> some View {
        Button { manager.adjustDelay(track: track, delta: delta) } label: { Image(systemName: symbol) }
            .barTip(text: AppLocalization.format(delta < 0 ? "bar.delay.earlier" : "bar.delay.later", "\(abs(delta)) ms"), $tip)
    }

    static func format(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func speedLabel(_ speed: Double) -> String { String(format: "%g×", speed) }
}

private extension View {
    /// Menus drawn like the bar's other plain buttons (the borderless menu style ignores the bar's white text).
    func barMenuStyle() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    /// Shows `key`'s text above the control bar while the pointer is over this control.
    func barTip(_ key: String, _ tip: Binding<String?>) -> some View {
        barTip(text: AppLocalization.string(key), tip)
    }

    func barTip(text: String, _ tip: Binding<String?>) -> some View {
        background(HoverArea { inside in
            if inside { tip.wrappedValue = text } else if tip.wrappedValue == text { tip.wrappedValue = nil }
        })
    }
}

/// Reports the pointer entering and leaving, even while another app is active (SwiftUI hover follows the key window).
private struct HoverArea: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Line alignment inside the overlay, so a track can be lined up without leaving the video.
private struct OverlayAlignPanel: View {
    @ObservedObject var manager: SubtitleManager
    @Binding var tip: String?
    @State private var track = "primary"
    @State private var search = ""
    @State private var selected: SubtitleItem?
    @State private var result = ""

    private var cues: [SubtitleItem] { SubtitleCueSearch.filter(manager.cues(track: track), query: search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("align.now").foregroundStyle(.secondary)
                Text(verbatim: ManualControlBar.format(manager.positionMs)).monospacedDigit().fontWeight(.semibold)
                if !manager.cues(track: "secondary").isEmpty {
                    // Drawn by hand: the system segmented control turns dark-on-dark while another app is active.
                    HStack(spacing: 2) {
                        ForEach([("primary", "manual.offset.primary"), ("secondary", "manual.offset.secondary")], id: \.0) { tag, title in
                            Button { track = tag } label: {
                                Text(LocalizedStringKey(title))
                                    .foregroundStyle(track == tag ? Color.white : Color.white.opacity(0.6))
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(track == tag ? Color.accentColor : .clear))
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.12)))
                    .fixedSize()
                }
                OverlaySearchField(text: $search, placeholder: AppLocalization.string("align.search"))
                    .frame(height: 20)
                Button { OverlayController.shared.isAligning = false } label: { Image(systemName: "xmark.circle.fill") }
                    .barTip("bar.close", $tip)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(cues, id: \.self) { cue in
                            HStack(alignment: .top, spacing: 8) {
                                Text(verbatim: ManualControlBar.format(cue.startMs)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                Text(verbatim: SubtitleCueSearch.displayText(cue)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(selected == cue ? Color.accentColor.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                            .onTapGesture { selected = cue; result = "" }
                        }
                    }
                }
                .frame(height: 150)
                .onAppear { scrollToNow(proxy) }
                .onChange(of: track) { _, _ in selected = nil; result = ""; scrollToNow(proxy) }
                .onChange(of: search) { _, text in if text.isEmpty { scrollToNow(proxy) } }
                .onChange(of: manager.loadID) { _, _ in selected = nil; result = ""; scrollToNow(proxy) }
            }
            HStack(spacing: 10) {
                Button {
                    guard let selected else { return }
                    result = SubtitleAlignView.message(forDelay: manager.align(track: track, to: selected))
                } label: {
                    Text("align.apply").padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(selected == nil ? 0.3 : 0.9)))
                }
                .disabled(selected == nil)
                .barTip("align.hint", $tip)
                if !result.isEmpty { Text(verbatim: result).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 0)
                Text(AppLocalization.format("playback.speed", ManualControlBar.speedLabel(manager.playbackSpeed)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    /// Brings the line that should be on screen now (at the track's current delay) into view.
    private func scrollToNow(_ proxy: ScrollViewProxy) {
        let offset = track == "secondary" ? manager.secondaryOffsetMs : manager.timeOffsetMs
        guard let target = SubtitleCueSearch.nearest(in: cues, atFileMs: manager.positionMs - offset) else { return }
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
    }
}

/// Search box for the overlay: like `DelayField`, it takes keyboard focus only while being edited.
private struct OverlaySearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = DelayField.KeyableTextField()
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.14)
        field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.45), .font: NSFont.systemFont(ofSize: 12)
        ])
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidBeginEditing(_ notification: Notification) {
            OverlayController.shared.isEditing = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }
            control.window?.makeFirstResponder(nil)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            OverlayController.shared.isEditing = false
            if let panel = (notification.object as? NSTextField)?.window as? OverlayPanel {
                panel.allowsKey = false
                panel.resignKey()
            }
        }
    }
}

/// Parses typed delays: "250", "-1500", "+300ms", "1.5s".
func parseDelayInput(_ text: String) -> Int? {
    var value = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
    var scale = 1.0
    if value.hasSuffix("ms") { value.removeLast(2) } else if value.hasSuffix("s") { value.removeLast(); scale = 1000 }
    guard let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite, abs(number * scale) <= 86_400_000 else { return nil }
    return Int((number * scale).rounded())
}

/// Editable delay value. The overlay panel normally cannot take keyboard focus, so this field lets it while editing.
struct DelayField: NSViewRepresentable {
    let value: Int
    let onCommit: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = KeyableTextField()
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.textColor = .white
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.14)
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.editing { field.stringValue = String(format: "%+d", value) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DelayField?
        var editing = false

        func controlTextDidBeginEditing(_ notification: Notification) {
            editing = true
            OverlayController.shared.isEditing = true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                (control as? NSTextField)?.stringValue = String(format: "%+d", parent?.value ?? 0)
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let ms = parseDelayInput(field.stringValue) { parent?.onCommit(ms) }
            editing = false
            field.stringValue = String(format: "%+d", parent?.value ?? 0)
            OverlayController.shared.isEditing = false
            if let panel = field.window as? OverlayPanel {
                panel.allowsKey = false
                panel.resignKey()
            }
        }
    }

    final class KeyableTextField: NSTextField {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if let panel = window as? OverlayPanel, !panel.isKeyWindow {
                panel.allowsKey = true
                panel.makeKey()
            }
            super.mouseDown(with: event)
        }
    }
}
