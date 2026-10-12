import SwiftUI

/// Aligns a track by picking a cue: if the line that appeared at 8:00 in the file is being spoken now (10:00),
/// the delay becomes +2:00.
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
                            let delay = manager.align(track: track, to: selected)
                            result = AppLocalization.format("align.result", String(format: "%+d ms", delay))
                        }
                        .disabled(selected == nil)
                        if !result.isEmpty { Text(verbatim: result).foregroundStyle(.secondary) }
                    }
                    SettingsHint(key: "align.hint")
                }
            }
        }
        .onChange(of: track) { _, _ in selected = nil; result = "" }
    }
}
