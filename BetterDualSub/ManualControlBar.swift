//
//  ManualControlBar.swift
//  BetterDualSub
//

import SwiftUI
import AppKit

/// Playback controls shown over the subtitles while the manual clock is driving them.
struct ManualControlBar: View {
    @ObservedObject var manager: SubtitleManager
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var resumeAfterScrub = false

    private var hasSecondTrack: Bool { manager.trackNames.count > 1 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { manager.seek(byMs: -10_000) } label: { Image(systemName: "gobackward.10") }
                Button { manager.togglePlay() } label: {
                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                Button { manager.seek(byMs: 10_000) } label: { Image(systemName: "goforward.10") }
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
                Text(Self.format(manager.durationMs)).monospacedDigit().foregroundStyle(.secondary)
                if manager.activeSource == .manual {
                Menu {
                    ForEach(SubtitleManager.manualSpeeds, id: \.self) { speed in
                        Button { manager.setManualSpeed(speed) } label: {
                            Text(verbatim: Self.speedLabel(speed) + (speed == manager.manualSpeed ? " ✓" : ""))
                        }
                    }
                } label: { Text(verbatim: Self.speedLabel(manager.manualSpeed)).monospacedDigit() }
                .menuStyle(.borderlessButton).fixedSize()
                }
                Menu {
                    Button("sync.mode.auto") { manager.setSyncMode(.auto) }
                    Button("sync.mode.manual") { manager.setSyncMode(.manual) }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 14) {
                offsetControl(title: hasSecondTrack && manager.linkSecondaryDelay ? "manual.offset.both" : "manual.offset.primary",
                              value: manager.timeOffsetMs, track: "primary")
                if hasSecondTrack {
                    Button { manager.setLink(!manager.linkSecondaryDelay) } label: {
                        Image(systemName: "link").opacity(manager.linkSecondaryDelay ? 1 : 0.4)
                    }
                    .help("manual.offset.linkHint")
                    if !manager.linkSecondaryDelay {
                        offsetControl(title: "manual.offset.secondary", value: manager.secondaryOffsetMs, track: "secondary")
                    }
                }
                Button { AppDelegate.shared?.showControlCenter(page: "align") } label: { Image(systemName: "scope") }
                    .help("align.open")
                Button { OverlayController.setLocked(true) } label: { Image(systemName: "lock.open") }
                    .help("overlay.lock")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.72)))
    }

    private func offsetControl(title: LocalizedStringKey, value: Int, track: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Button { manager.adjustDelay(track: track, delta: -SubtitleDelayStep.milliseconds) } label: { Image(systemName: "minus.circle") }
            DelayField(value: value) { manager.setDelay(track: track, ms: $0) }
                .frame(width: 64, height: 20)
            Text("ms").foregroundStyle(.secondary)
            Button { manager.adjustDelay(track: track, delta: SubtitleDelayStep.milliseconds) } label: { Image(systemName: "plus.circle") }
            Button { manager.adjustDelay(track: track, delta: Int.min) } label: { Image(systemName: "arrow.counterclockwise") }
        }
    }

    static func format(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func speedLabel(_ speed: Double) -> String { String(format: "%g×", speed) }
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
