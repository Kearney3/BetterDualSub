import SwiftUI

/// Home page of the control center: getting started while nothing is loaded, then everything about the loaded
/// subtitles (tracks, sync, timing, translation) in one place.
struct NowPlayingView: View {
    @EnvironmentObject private var manager: SubtitleManager
    @AppStorage(OverlayController.visibleKey) private var showWindow = true

    private var hasSubtitles: Bool { !manager.trackNames.isEmpty }

    var body: some View {
        SettingsPage {
            if hasSubtitles { loadedHeader } else { welcome }

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
                steps
                tips
            }
        }
        .onChange(of: showWindow) { _, _ in NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil) }
    }

    // MARK: Loaded

    private var loadedHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: manager.loadedTitle.isEmpty ? AppLocalization.string("common.loaded.title") : manager.loadedTitle)
                .font(.title.weight(.semibold))
                .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                trackRow("nowPlaying.track.primary", manager.trackNames.first)
                trackRow("nowPlaying.track.secondary", manager.trackNames.count > 1 ? manager.trackNames[1] : nil)
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
            HStack(spacing: 10) {
                ForEach(LoadSource.allCases) { sourceButton($0) }
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    /// Your own subtitle file, the first source, is the prominent one.
    @ViewBuilder
    private func sourceButton(_ source: LoadSource) -> some View {
        let button = Button {
            showControlCenterPage(Self.pageName(for: source))
        } label: {
            Label(LocalizedStringKey(source.titleKey), systemImage: source.symbol)
        }
        if source == .file { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
    }

    /// The control center's name for the Load Subtitles page opened on `source`.
    private static func pageName(for source: LoadSource) -> String {
        switch source {
        case .movie: "movie"
        case .episode: "localPackage"
        case .file: "localFile"
        }
    }

    private var steps: some View {
        SettingsCard(titleKey: "guide.steps.title") {
            step(1, "film", "guide.step1.title", "guide.step1.body", complete: hasSubtitles) {
                Button("nav.load") { showControlCenterPage("load") }
            }
            Divider()
            step(2, "play.rectangle.on.rectangle", "guide.step2.title", "guide.step2.body", complete: manager.syncStatus.isFollowing) {
                Button("nav.general") { showControlCenterPage("general") }
            }
            Divider()
            step(3, "slider.horizontal.3", "guide.step3.title", "guide.step3.body", complete: false) {
                Button("guide.step3.appearance") { showControlCenterPage("appearance") }
                Button("guide.step3.shortcuts") { showControlCenterPage("shortcuts") }
            }
        }
    }

    private var tips: some View {
        SettingsCard(titleKey: "guide.tips.title") {
            tip("menubar.rectangle", "guide.tip.menuBar")
            tip("keyboard", "guide.tip.shortcuts")
            tip("rectangle.on.rectangle", "guide.tip.overlay")
            tip("hand.raised", "guide.tip.privacy")
        }
    }

    private func step<Actions: View>(_ number: Int, _ symbol: String, _ title: LocalizedStringKey,
                                     _ body: LocalizedStringKey, complete: Bool,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: complete ? "checkmark.circle.fill" : symbol)
                .font(.title3)
                .foregroundStyle(complete ? Color.green : Color.accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) { actions() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
    }

    private func tip(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(key).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
