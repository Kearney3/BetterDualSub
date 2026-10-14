import SwiftUI

/// Aligns a track by picking a cue: if the line that appeared at 8:00 in the file is being spoken now (10:00),
/// the delay becomes +2:00. Aligning a second line later in the video also corrects the track's speed.
struct SubtitleAlignView: View {
    @EnvironmentObject private var manager: SubtitleManager
    @State private var track = "primary"
    @State private var search = ""
    @State private var selected: SubtitleItem?
    @State private var result = ""

    private var cues: [SubtitleItem] {
        let all = manager.cues(track: track)
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        SettingsPage(descriptionKey: "align.description") {
            if manager.trackNames.isEmpty {
                SettingsCard { SettingsRow(symbol: "circle.dashed", tint: .secondary, titleKey: "guide.status.empty") { EmptyView() } }
            } else {
                SettingsCard {
                    HStack {
                        Text("align.now")
                        Text(verbatim: ManualControlBar.format(manager.positionMs)).monospacedDigit().font(.title3.weight(.semibold))
                        Spacer()
                        if manager.cues(track: "secondary").isEmpty == false {
                            Picker("align.track", selection: $track) {
                                Text("manual.offset.primary").tag("primary")
                                Text("manual.offset.secondary").tag("secondary")
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                    }
                    TextField("align.search", text: $search).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(cues, id: \.self) { cue in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(verbatim: ManualControlBar.format(cue.startMs)).monospacedDigit().foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .leading)
                                    Text(verbatim: cue.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4).padding(.horizontal, 8)
                                .background(selected == cue ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { selected = cue; result = "" }
                            }
                        }
                    }
                    .frame(height: 320)
                    HStack {
                        Button("align.apply") {
                            guard let selected else { return }
                            result = Self.message(for: manager.align(track: track, to: selected))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected == nil)
                        if !result.isEmpty { Text(verbatim: result).foregroundStyle(.secondary) }
                    }
                    SettingsHint(key: "align.hint")
                }
                SettingsCard(titleKey: "align.speed.title") {
                    if let point = manager.alignPoints[track] {
                        HStack(alignment: .firstTextBaseline) {
                            Text(AppLocalization.format("align.point.first", ManualControlBar.format(point.fileMs),
                                                        ManualControlBar.format(point.videoMs)))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("align.point.clear") { manager.clearAlignPoint(track: track); result = "" }
                                .controlSize(.small)
                        }
                    } else {
                        Text("align.point.none").foregroundStyle(.secondary)
                    }
                    let speed = manager.speed(track: track)
                    HStack {
                        Text(AppLocalization.format("align.speed.value", String(format: "%.4f", speed))).monospacedDigit()
                        Spacer()
                        Button("align.speed.reset") { manager.setSpeed(track: track, 1) }
                            .controlSize(.small)
                            .disabled(speed == 1)
                    }
                    SettingsHint(key: "align.speed.help")
                }
            }
        }
        .onChange(of: track) { _, _ in selected = nil; result = "" }
        .onChange(of: manager.loadID) { _, _ in selected = nil; result = "" }
    }

    private static func message(for result: SubtitleManager.AlignResult) -> String {
        switch result {
        case .delay(let delay):
            AppLocalization.format("align.result", String(format: "%+d ms", delay))
        case .speed(let scale, let delay) where scale == 1:
            AppLocalization.format("align.result.noDrift", String(format: "%+d ms", delay))
        case .speed(let scale, let delay):
            AppLocalization.format("align.result.speed", String(format: "%.4f", scale), String(format: "%+d ms", delay))
        case .implausible(let scale):
            AppLocalization.format("align.error.speed", String(format: "%.3f", scale))
        }
    }
}
