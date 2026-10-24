import SwiftUI

/// Aligns a track by picking a cue: if the line that appeared at 8:00 in the file is being spoken now (10:00),
/// the delay becomes +2:00. Subtitle time runs 1:1 with video time, at whatever speed the video plays.
struct SubtitleAlignView: View {
    @EnvironmentObject private var manager: SubtitleManager
    @State private var track = "primary"
    @State private var search = ""
    @State private var selected: SubtitleItem?
    @State private var result = ""
    /// Cues matching the search; recomputed only when the search, track or subtitles change, not on every clock tick.
    @State private var cues: [SubtitleItem] = []

    /// The cue that should be on screen now at the track's current delay.
    private var currentCue: SubtitleItem? {
        let offset = track == "secondary" ? manager.secondaryOffsetMs : manager.timeOffsetMs
        return SubtitleCueSearch.current(in: manager.cues(track: track), atFileMs: manager.positionMs - offset)
    }

    var body: some View {
        let current = currentCue
        SettingsPage(descriptionKey: "align.description") {
            if manager.trackNames.isEmpty {
                SettingsCard { SettingsRow(symbol: "circle.dashed", tint: .secondary, titleKey: "guide.status.empty") { EmptyView() } }
            } else {
                SettingsCard {
                    HStack {
                        Text("align.now")
                        Text(verbatim: ManualControlBar.format(manager.positionMs)).monospacedDigit().font(.title3.weight(.semibold))
                        Text(AppLocalization.format("playback.speed", ManualControlBar.speedLabel(manager.playbackSpeed)))
                            .monospacedDigit().foregroundStyle(.secondary)
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
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(cues, id: \.self) { cue in row(cue, isCurrent: cue == current) }
                            }
                        }
                        .frame(height: 320)
                        .overlay {
                            if cues.isEmpty && !search.isEmpty {
                                Text("align.noMatch").foregroundStyle(.secondary)
                            }
                        }
                        .onAppear { scrollToCurrent(proxy, animated: false) }
                        .onChange(of: track) { _, _ in scrollToCurrent(proxy, animated: false) }
                        .onChange(of: manager.loadID) { _, _ in scrollToCurrent(proxy, animated: false) }
                        HStack {
                            Button("align.apply") {
                                guard let selected else { return }
                                result = Self.message(forDelay: manager.align(track: track, to: selected))
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selected == nil)
                            if !result.isEmpty { Text(verbatim: result).foregroundStyle(.secondary) }
                            Spacer()
                            Button { scrollToCurrent(proxy, animated: true) } label: {
                                Label("align.jumpToCurrent", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .disabled(current == nil)
                        }
                    }
                    SettingsHint(key: "align.hint")
                }
            }
        }
        .onAppear(perform: refreshCues)
        .onChange(of: search) { _, _ in refreshCues() }
        .onChange(of: track) { _, _ in selected = nil; result = ""; refreshCues() }
        .onChange(of: manager.loadID) { _, _ in selected = nil; result = ""; refreshCues() }
    }

    private func row(_ cue: SubtitleItem, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 14)
                .accessibilityHidden(!isCurrent)
            Text(verbatim: ManualControlBar.format(cue.startMs)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(verbatim: SubtitleCueSearch.displayText(cue)).lineLimit(2)
                .fontWeight(isCurrent ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(selected == cue ? Color.accentColor.opacity(0.22) : isCurrent ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selected = cue; result = "" }
    }

    private func refreshCues() {
        cues = SubtitleCueSearch.filter(manager.cues(track: track), query: search)
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        let offset = track == "secondary" ? manager.secondaryOffsetMs : manager.timeOffsetMs
        guard let target = SubtitleCueSearch.nearest(in: cues, atFileMs: manager.positionMs - offset) else { return }
        DispatchQueue.main.async {
            if animated { withAnimation { proxy.scrollTo(target, anchor: .center) } } else { proxy.scrollTo(target, anchor: .center) }
        }
    }

    static func message(forDelay delay: Int) -> String {
        AppLocalization.format("align.result", String(format: "%+d ms", delay))
    }
}

/// Cue lookups shared by the alignment list in the control center and the one over the subtitles.
enum SubtitleCueSearch {
    /// One line of plain text, without markup.
    static func displayText(_ cue: SubtitleItem) -> String {
        SubtitleMarkup.plainText(cue.text).replacingOccurrences(of: "\n", with: " ")
    }

    static func filter(_ cues: [SubtitleItem], query: String) -> [SubtitleItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return cues }
        return cues.filter { displayText($0).localizedCaseInsensitiveContains(query) }
    }

    /// The cue showing at `fileMs`, if any (the latest-starting one when cues overlap).
    static func current(in cues: [SubtitleItem], atFileMs fileMs: Int) -> SubtitleItem? {
        guard let cue = nearest(in: cues, atFileMs: fileMs), cue.startMs <= fileMs, fileMs < cue.endMs else { return nil }
        return cue
    }

    /// The last cue starting by `fileMs`, else the first one: where to look in the list.
    static func nearest(in cues: [SubtitleItem], atFileMs fileMs: Int) -> SubtitleItem? {
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].startMs <= fileMs { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? cues[low - 1] : cues.first
    }
}
