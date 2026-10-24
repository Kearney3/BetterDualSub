import SwiftUI

/// Home page of the control center: getting started while nothing is loaded, then everything about the loaded
/// subtitles (tracks, sync, timing, translation) in one place.
struct NowPlayingView: View {
    @EnvironmentObject private var manager: SubtitleManager
    @AppStorage(OverlayController.visibleKey) private var showWindow = true
    @AppStorage(ViewingGuide.completedKey) private var guideCompleted = false

    private var hasSubtitles: Bool { !manager.trackNames.isEmpty }

    var body: some View {
        SettingsPage {
            if hasSubtitles { loadedHeader } else { welcome }
            GettingStartedCard()

            SettingsCard {
                SyncStatusDetail()
                Divider()
                SettingsRow(symbol: "macwindow", tint: .blue, titleKey: "appearance.window.show", subtitleKey: "appearance.window.help") {
                    Toggle("appearance.window.show", isOn: $showWindow).labelsHidden().toggleStyle(.switch)
                }
            }

            if hasSubtitles {
                SubtitleTimingCard()
                SubtitleTranslationCard()
            } else {
                tips
            }
            RecentWatchingCard(limit: 3)
        }
        .onChange(of: showWindow) { _, _ in NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil) }
    }

    // MARK: Loaded

    private var loadedHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: manager.loadedTitle.isEmpty ? AppLocalization.string("common.loaded.title") : manager.loadedTitle)
                .font(.title.weight(.semibold))
                .textSelection(.enabled)
            if let choice = manager.packageTracks {
                packageTrackPickers(choice)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    trackRow("nowPlaying.track.primary", manager.trackNames.first)
                    trackRow("nowPlaying.track.secondary", manager.trackNames.count > 1 ? manager.trackNames[1] : nil)
                }
            }
            HStack(spacing: 10) {
                Button("nowPlaying.change") { showControlCenterPage("load") }
                    .buttonStyle(.glass)
                Button("align.open") { showControlCenterPage("align") }
                    .buttonStyle(.glass)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    /// Subtitles extracted from a package can switch to its other tracks without losing their delay.
    private func packageTrackPickers(_ choice: PackageTrackChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("nowPlaying.track.primary").foregroundStyle(.secondary)
                    Picker("nowPlaying.track.primary", selection: Binding(get: { choice.primaryID },
                                                                           set: { manager.switchPackageTracks(primaryID: $0) })) {
                        ForEach(choice.tracks) { Text(verbatim: $0.label).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text("nowPlaying.track.secondary").foregroundStyle(.secondary)
                    Picker("nowPlaying.track.secondary", selection: Binding(get: { choice.secondaryID ?? Self.otherTrackTag },
                                                                             set: { manager.switchPackageTracks(secondaryID: $0) })) {
                        Text("download.noSecondary").tag("")
                        if choice.secondaryID == nil, manager.trackNames.count > 1 {
                            Text(verbatim: manager.trackNames[1]).tag(Self.otherTrackTag)
                        }
                        ForEach(choice.tracks) { Text(verbatim: $0.label).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            .disabled(manager.switchingTracks)
            if let error = manager.trackSwitchError {
                StatusLine(text: error, isError: true)
            } else {
                SettingsHint(key: "nowPlaying.tracks.help")
            }
        }
    }

    /// Picker tag for a Track 2 that is not one of the package's tracks (a translation); choosing it changes nothing.
    private static let otherTrackTag = "\u{0}other"

    private func trackRow(_ label: LocalizedStringKey, _ name: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            if let name {
                Text(verbatim: name).lineLimit(1).truncationMode(.middle)
            } else {
                Text("nowPlaying.track.none").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Nothing loaded

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
            Text("BetterDualSub")
                .font(.largeTitle.weight(.semibold))
            Text("guide.description")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // While the Getting Started checklist is up, its first step offers the same sources.
            if guideCompleted {
                HStack(spacing: 10) {
                    ForEach(LoadSource.allCases) { sourceButton($0) }
                }
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    /// Your own subtitle file, the first source, is the prominent one.
    @ViewBuilder
    private func sourceButton(_ source: LoadSource) -> some View {
        let button = Button {
            showControlCenterPage(source.pageName)
        } label: {
            Label(LocalizedStringKey(source.titleKey), systemImage: source.symbol)
        }
        if source == .file { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
    }

    private var tips: some View {
        SettingsCard(titleKey: "guide.tips.title") {
            tip("menubar.rectangle", "guide.tip.menuBar")
            tip("keyboard", "guide.tip.shortcuts")
            tip("rectangle.on.rectangle", "guide.tip.overlay")
            tip("hand.raised", "guide.tip.privacy")
        }
    }

    private func tip(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(key).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
