import SwiftUI
import AppKit
import Carbon.HIToolbox

enum SubtitleShortcutAction: Int, CaseIterable, Identifiable {
    case primaryEarlier = 1
    case primaryLater
    case secondaryEarlier
    case secondaryLater
    case primaryReset
    case secondaryReset
    case manualPlayPause
    case manualBack
    case manualForward
    case toggleLock

    var id: Int { rawValue }

    var titleKey: String {
        switch self {
        case .primaryEarlier: "shortcuts.action.primaryEarlier"
        case .primaryLater: "shortcuts.action.primaryLater"
        case .secondaryEarlier: "shortcuts.action.secondaryEarlier"
        case .secondaryLater: "shortcuts.action.secondaryLater"
        case .primaryReset: "shortcuts.action.primaryReset"
        case .secondaryReset: "shortcuts.action.secondaryReset"
        case .manualPlayPause: "shortcuts.action.manualPlayPause"
        case .manualBack: "shortcuts.action.manualBack"
        case .manualForward: "shortcuts.action.manualForward"
        case .toggleLock: "shortcuts.action.toggleLock"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .primaryEarlier, .secondaryEarlier, .manualBack: UInt16(kVK_LeftArrow)
        case .primaryLater, .secondaryLater, .manualForward: UInt16(kVK_RightArrow)
        case .manualPlayPause: UInt16(kVK_Space)
        case .toggleLock: UInt16(kVK_ANSI_L)
        case .primaryReset, .secondaryReset: UInt16(kVK_ANSI_0)
        }
    }

    var isManualPlayback: Bool { self == .manualPlayPause || self == .manualBack || self == .manualForward }

    var modifiers: UInt32 {
        if self == .toggleLock { return UInt32(controlKey | optionKey) }
        if isManualPlayback { return UInt32(controlKey | optionKey | cmdKey) }
        return UInt32(controlKey | optionKey) | (track == "secondary" ? UInt32(shiftKey) : 0)
    }

    var track: String { [.secondaryEarlier, .secondaryLater, .secondaryReset].contains(self) ? "secondary" : "primary" }
    var isReset: Bool { self == .primaryReset || self == .secondaryReset }
    var delta: Int {
        if isReset { return Int.min }
        return self == .primaryEarlier || self == .secondaryEarlier
            ? -SubtitleDelayStep.milliseconds : SubtitleDelayStep.milliseconds
    }
}

enum SubtitleDelayStep {
    static var milliseconds: Int {
        guard let stored = UserDefaults.standard.object(forKey: "subtitleDelayStepMs") as? Int else { return 250 }
        return min(60_000, max(1, stored))
    }
}

struct ShortcutChord: Equatable {
    var keyCode: UInt16
    var modifiers: UInt32

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyNames[keyCode] ?? "Key \(keyCode)"
        return result
    }

    private static let keyNames: [UInt16: String] = [
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Delete): "Delete", UInt16(kVK_Escape): "Escape",
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9"
    ]
}

enum SubtitleShortcutPreferences {
    static func chord(for action: Int) -> ShortcutChord {
        let command = SubtitleShortcutAction(rawValue: action) ?? .primaryEarlier
        let defaults = UserDefaults.standard
        let keyCodeKey = "subtitleShortcut.\(action).keyCode"
        let modifiersKey = "subtitleShortcut.\(action).modifiers"
        let keyCode = defaults.object(forKey: keyCodeKey).map { UInt16(truncatingIfNeeded: ($0 as? Int) ?? 0) } ?? command.keyCode
        let modifiers = defaults.object(forKey: modifiersKey).map { UInt32(truncatingIfNeeded: ($0 as? Int) ?? 0) } ?? command.modifiers
        return ShortcutChord(keyCode: keyCode, modifiers: modifiers)
    }

    static func save(_ chord: ShortcutChord, for action: Int) {
        UserDefaults.standard.set(Int(chord.keyCode), forKey: "subtitleShortcut.\(action).keyCode")
        UserDefaults.standard.set(Int(chord.modifiers), forKey: "subtitleShortcut.\(action).modifiers")
        NotificationCenter.default.post(name: .subtitleShortcutsChanged, object: nil)
    }

    static func reset() {
        for action in SubtitleShortcutAction.allCases {
            UserDefaults.standard.removeObject(forKey: "subtitleShortcut.\(action.id).keyCode")
            UserDefaults.standard.removeObject(forKey: "subtitleShortcut.\(action.id).modifiers")
        }
        NotificationCenter.default.post(name: .subtitleShortcutsChanged, object: nil)
    }
}

struct ShortcutSettingsView: View {
    @AppStorage("subtitleDelayStepMs") private var delayStepMs = 250
    @State private var recordingAction: Int?
    @State private var chords = Dictionary(uniqueKeysWithValues: SubtitleShortcutAction.allCases.map { ($0.id, SubtitleShortcutPreferences.chord(for: $0.id)) })
    @State private var message = ""
    @State private var delayStepText = ""

    var body: some View {
        SettingsPage(descriptionKey: "shortcuts.description") {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("shortcuts.step.title")
                            Spacer()
                            TextField("250", text: $delayStepText)
                                .frame(width: 100)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(saveDelayStep)
                            Text("common.unit.ms").foregroundStyle(.secondary)
                        }
                        Text("shortcuts.step.help")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("shortcuts.resetBoth", action: resetBothTracks)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                    Divider()
                    ForEach(SubtitleShortcutAction.allCases) { action in
                        shortcutRow(action)
                        if action != SubtitleShortcutAction.allCases.last { Divider() }
                    }
                }
                .padding(.horizontal, 18)
                .settingsCardBackground()
                HStack {
                    Button("shortcuts.restoreDefaults", action: reset)
                    if !message.isEmpty {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                SettingsHint(key: "shortcuts.help")
        }
        .onAppear { delayStepText = String(delayStepMs) }
        .onChange(of: delayStepText) { _, text in
            guard let value = Int(text), (1...60_000).contains(value), value != delayStepMs else { return }
            delayStepMs = value
            NotificationCenter.default.post(name: .subtitleDelayStepChanged, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in message = "" }
    }

    private func shortcutRow(_ action: SubtitleShortcutAction) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(action.titleKey)).font(.body.weight(.medium))
                Text(LocalizedStringKey(action.track == "primary" ? "shortcuts.track.primary" : "shortcuts.track.secondary"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(recordingAction == action.id ? AppLocalization.string("shortcuts.recording") : chords[action.id]?.displayName ?? "") {
                message = ""
                recordingAction = action.id
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 150)
            .overlay {
                if recordingAction == action.id {
                    HotKeyCaptureView(isRecording: true, onCapture: { keyCode, modifiers in
                        capture(keyCode: keyCode, modifiers: modifiers, for: action)
                    }, onCancel: { recordingAction = nil })
                        .frame(width: 2, height: 2)
                }
            }
        }
        .padding(.vertical, 15)
    }

    private func capture(keyCode: UInt16, modifiers: UInt32, for action: SubtitleShortcutAction) {
        guard modifiers != 0 else {
            message = AppLocalization.string("shortcuts.needModifier")
            return
        }
        let chord = ShortcutChord(keyCode: keyCode, modifiers: modifiers)
        if let conflict = chords.first(where: { $0.key != action.id && $0.value == chord }) {
            let title = SubtitleShortcutAction(rawValue: conflict.key)?.titleKey ?? ""
            message = AppLocalization.format("shortcuts.conflict", AppLocalization.string(title))
            return
        }
        chords[action.id] = chord
        SubtitleShortcutPreferences.save(chord, for: action.id)
        recordingAction = nil
        message = AppLocalization.string("shortcuts.saved")
    }

    private func reset() {
        SubtitleShortcutPreferences.reset()
        chords = Dictionary(uniqueKeysWithValues: SubtitleShortcutAction.allCases.map { ($0.id, SubtitleShortcutPreferences.chord(for: $0.id)) })
        recordingAction = nil
        message = AppLocalization.string("shortcuts.restored")
    }

    private func saveDelayStep() {
        guard let value = Int(delayStepText) else {
            delayStepText = String(delayStepMs)
            return
        }
        delayStepMs = min(60_000, max(1, value))
        delayStepText = String(delayStepMs)
        NotificationCenter.default.post(name: .subtitleDelayStepChanged, object: nil)
    }

    private func resetBothTracks() {
        for track in ["primary", "secondary"] {
            NotificationCenter.default.post(name: .adjustSubtitleDelay, object: nil,
                                            userInfo: ["track": track, "delta": Int.min])
        }
    }
}

private struct HotKeyCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: (UInt16, UInt32) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: KeyCaptureNSView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
        if isRecording {
            DispatchQueue.main.async {
                if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
            }
        }
    }
}

private final class KeyCaptureNSView: NSView {
    var onCapture: ((UInt16, UInt32) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        guard carbonModifiers != 0 else { NSSound.beep(); return }
        onCapture?(event.keyCode, carbonModifiers)
    }
}
