import SwiftUI

/// First-run state shared by the welcome sheet, the getting-started checklist and the overlay's first-load tip.
enum ViewingGuide {
    static let welcomeShownKey = "welcomeGuideShown"
    static let completedKey = "viewingSetupCompleted"
    static let visibilityConfirmedKey = "subtitleVisibilityConfirmed"
    static let overlayTipShownKey = "overlayTipShown"

    /// Shows the welcome sheet and the checklist again, as on a first launch. An open control center presents the
    /// sheet as soon as `welcomeShownKey` turns false; a closed one does when it opens.
    static func restart() {
        let defaults = UserDefaults.standard
        for key in [welcomeShownKey, completedKey, visibilityConfirmedKey, overlayTipShownKey] { defaults.set(false, forKey: key) }
    }

    /// Someone who used an earlier version (finished the setup or has watch history) is not greeted as new.
    static var isReturningUser: Bool {
        UserDefaults.standard.bool(forKey: completedKey) || FileManager.default.fileExists(
            atPath: URL.applicationSupportDirectory.appendingPathComponent("BetterDualSub/RecentWatching.json").path)
    }

    /// Opens the welcome sheet without resetting the checklist (Help menu).
    @MainActor
    static func showWelcome() {
        UserDefaults.standard.set(false, forKey: welcomeShownKey)
        AppDelegate.shared?.showControlCenter(page: nil)
    }
}

/// One-page introduction shown on the first launch: what the app does, the three steps to a first viewing, and a
/// start button that opens Load Subtitles.
struct WelcomeView: View {
    var onStart: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("welcome.title")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("welcome.subtitle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 36)
            .padding(.horizontal, 40)

            HStack(alignment: .top, spacing: 14) {
                step(1, "doc.badge.plus", "welcome.step.load.title", "welcome.step.load.body")
                step(2, "play.rectangle.on.rectangle", "welcome.step.play.title", "welcome.step.play.body")
                step(3, "slider.horizontal.3", "welcome.step.adjust.title", "welcome.step.adjust.body")
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)

            Label("welcome.privacy", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 22)
                .padding(.horizontal, 40)

            Spacer(minLength: 24)

            HStack {
                Button("welcome.later", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: onStart) {
                    Text("welcome.start").padding(.horizontal, 12)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 26)
        }
        .frame(width: 720, height: 540)
    }

    private func step(_ number: Int, _ symbol: String, _ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconTile(symbol: symbol, size: 38)
                Spacer()
                Text(verbatim: "\(number)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.quaternary)
                    .accessibilityHidden(true)
            }
            Text(title).font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .settingsCardBackground()
        .accessibilityElement(children: .combine)
    }
}

/// The steps to a first working viewing, checked off live: subtitles loaded, a player followed, the overlay seen.
/// The first open step shows its explanation and fix; the card goes away once the user is done with it.
struct GettingStartedCard: View {
    @EnvironmentObject private var manager: SubtitleManager
    @AppStorage(OverlayController.visibleKey) private var overlayVisible = true
    @AppStorage(ViewingGuide.completedKey) private var completed = false
    @AppStorage(ViewingGuide.visibilityConfirmedKey) private var confirmed = false

    private enum Step: Int, CaseIterable { case load, player, visible }

    private var loaded: Bool { !manager.trackNames.isEmpty }
    private var clockReady: Bool { manager.syncStatus.isFollowing || manager.syncStatus == .manual }

    private func isDone(_ step: Step) -> Bool {
        switch step {
        case .load: loaded
        case .player: clockReady
        case .visible: loaded && overlayVisible && confirmed
        }
    }

    private var doneCount: Int { Step.allCases.filter(isDone).count }
    private var current: Step? { Step.allCases.first { !isDone($0) } }

    var body: some View {
        if !completed {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("onboarding.title").font(.headline)
                    Spacer()
                    Text(AppLocalization.format("onboarding.progress", doneCount, Step.allCases.count))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button { completed = true } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("onboarding.dismiss")
                        .accessibilityLabel("onboarding.dismiss")
                }
                ProgressView(value: Double(doneCount), total: Double(Step.allCases.count))
                    .tint(doneCount == Step.allCases.count ? .green : .accentColor)
                ForEach(Step.allCases, id: \.self) { step in
                    row(step)
                    if step != Step.allCases.last { Divider() }
                }
                if current == nil {
                    HStack(spacing: 10) {
                        Image(systemName: "party.popper.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("onboarding.done.title").font(.headline)
                            Text("onboarding.done.body").font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("onboarding.finish") { withAnimation { completed = true } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCardBackground()
            .animation(.easeInOut(duration: 0.2), value: doneCount)
        }
    }

    @ViewBuilder
    private func row(_ step: Step) -> some View {
        let done = isDone(step), active = step == current
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : active ? Color.accentColor : Color.secondary.opacity(0.18))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(step.rawValue + 1)").font(.caption.weight(.bold))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title(step))
                    .font(.body.weight(active ? .semibold : .regular))
                    .foregroundStyle(done || active ? Color.primary : Color.secondary)
                if active {
                    Text(verbatim: detail(step))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    actions(step).controlSize(.small).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Text(done ? "ready.status.complete" : "ready.status.pending")
                .font(.caption).foregroundStyle(done ? Color.green : Color.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private func title(_ step: Step) -> LocalizedStringKey {
        switch step {
        case .load: "onboarding.load.title"
        case .player: manager.syncStatus == .manual ? "ready.manual" : "onboarding.player.title"
        case .visible: "onboarding.visible.title"
        }
    }

    private func detail(_ step: Step) -> String {
        switch step {
        case .load: AppLocalization.string("onboarding.load.body")
        case .player:
            if case .waiting(let other?) = manager.syncStatus {
                AppLocalization.format("sync.status.otherApp.help", other.name, SyncTarget.currentName)
            } else {
                AppLocalization.format("onboarding.player.body", SyncTarget.currentName)
            }
        case .visible: AppLocalization.string(overlayVisible ? "onboarding.visible.body" : "onboarding.visible.hidden")
        }
    }

    @ViewBuilder
    private func actions(_ step: Step) -> some View {
        HStack(spacing: 10) {
            switch step {
            case .load:
                ForEach(LoadSource.allCases) { source in
                    Button { showControlCenterPage(source.pageName) } label: {
                        Label(LocalizedStringKey(source.titleKey), systemImage: source.symbol)
                    }
                }
            case .player:
                if case .waiting(let other?) = manager.syncStatus {
                    Button(AppLocalization.format("sync.action.follow", other.name)) { manager.follow(other) }
                        .buttonStyle(.borderedProminent)
                } else if manager.syncStatus == .disconnected {
                    Button("sync.action.reconnect") { manager.reconnect() }
                }
                Button("onboarding.player.choose") { showControlCenterPage("general") }
                Button("onboarding.player.manual") { manager.setSyncMode(.manual) }
            case .visible:
                if overlayVisible {
                    Button("onboarding.visible.confirm") { confirmed = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("ready.show") { OverlayController.setVisible(true) }
                        .buttonStyle(.borderedProminent)
                }
                Button("guide.step3.appearance") { showControlCenterPage("appearance") }
            }
        }
    }
}

extension LoadSource {
    /// The control center's name for the Load Subtitles page opened on this source.
    var pageName: String {
        switch self {
        case .movie: "movie"
        case .episode: "localPackage"
        case .file: "localFile"
        }
    }
}
