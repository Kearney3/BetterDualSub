import AppKit
import Combine
import OSLog
import Sparkle

/// Looks up the latest GitHub release and tells the user when it is newer than the running app. Nothing is downloaded
/// until the user asks, and then Sparkle installs it in the app. The Homebrew cask is marked `auto_updates`, so `brew`
/// leaves such upgrades to the app.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let autoCheckKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    /// The newest release seen, as [version, page URL], so a found update is still offered after a relaunch.
    private static let latestKey = "latestRelease"
    /// The tag GitHub gave the saved release's answer; sent back so an unchanged answer costs nothing.
    private static let etagKey = "latestReleaseETag"
    static let frequencyKey = "updateCheckInterval"
    /// How often a running app looks at whether a check is due. The app often stays open for days.
    private static let scheduleInterval: TimeInterval = 3600

    /// How long an answer from GitHub is good for before an automatic check asks again; the raw value is in seconds.
    enum Frequency: Int, CaseIterable, Identifiable {
        case daily = 86_400
        case weekly = 604_800
        /// Thirty days.
        case monthly = 2_592_000

        var id: Int { rawValue }

        var titleKey: String {
            switch self {
            case .daily: "update.frequency.daily"
            case .weekly: "update.frequency.weekly"
            case .monthly: "update.frequency.monthly"
            }
        }

        static var current: Frequency {
            Frequency(rawValue: UserDefaults.standard.integer(forKey: UpdateChecker.frequencyKey)) ?? .daily
        }
    }

    typealias Release = ReleaseLookup.Release

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// When GitHub last answered, for the settings page.
    @Published private(set) var lastChecked = UserDefaults.standard.object(forKey: UpdateChecker.lastCheckKey) as? Date

    /// Download a found update in the background and install it when the app quits, without asking. Sparkle keeps
    /// the choice (`SUAutomaticallyUpdate`); Info.plist allows it although Sparkle's own scheduled checks are off.
    @Published var installsAutomatically = false {
        didSet {
            guard installsAutomatically != oldValue, Self.canInstallInApp else { return }
            sparkle.updater.automaticallyDownloadsUpdates = installsAutomatically
            installIfAutomatic()
        }
    }

    /// Sparkle installs updates, when the user asks or automatically; its own scheduled checks are off in Info.plist.
    private let sparkle = SPUStandardUpdaterController(startingUpdater: UpdateChecker.canInstallInApp,
                                                       updaterDelegate: nil, userDriverDelegate: nil)
    private var schedule: Timer?
    private var wakeObserver: NSObjectProtocol?

    var available: Release? {
        if case .available(let release) = state { release } else { nil }
    }

    static var currentVersion: AppVersion? { AppVersion(Bundle.main.appVersion) }

    /// Built with the release signing key (local builds are not), so the app can download and install updates itself.
    static var canInstallInApp: Bool {
        !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
    }

    /// Shows Sparkle's update window, which downloads, verifies and installs the update, then relaunches.
    func installUpdate() {
        guard Self.canInstallInApp else { return }
        sparkle.checkForUpdates(nil)
    }

    private init() {
        if let saved = Self.savedRelease, Self.isNewer(saved.version) { state = .available(saved) }
        if Self.canInstallInApp { installsAutomatically = sparkle.updater.automaticallyDownloadsUpdates }
    }

    /// With automatic installation on, hands a found update to Sparkle, which downloads and verifies it without a
    /// window and installs it when the app quits.
    private func installIfAutomatic() {
        guard Self.canInstallInApp, installsAutomatically, available != nil, !sparkle.updater.sessionInProgress else { return }
        sparkle.updater.checkForUpdatesInBackground()
    }

    private static var savedRelease: Release? {
        guard let saved = UserDefaults.standard.stringArray(forKey: latestKey), saved.count == 2,
              let version = AppVersion(saved[0]), let page = URL(string: saved[1]) else { return nil }
        return Release(version: version, page: page)
    }

    /// Checks now if one is due, then again whenever one becomes due while the app runs, and after the Mac wakes.
    func startAutomaticChecks() {
        checkIfDue()
        // An update found before the last quit that was not installed then.
        installIfAutomatic()
        guard schedule == nil else { return }
        let timer = Timer(timeInterval: Self.scheduleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        schedule = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The network is rarely back the moment the Mac wakes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self?.checkIfDue() }
        }
    }

    /// Checks when automatic checks are on and the last answer is older than the chosen frequency.
    func checkIfDue() {
        guard UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true,
              ReleaseLookup.isDue(lastCheck: lastChecked, interval: TimeInterval(Frequency.current.rawValue)) else { return }
        Task { await check(userInitiated: false) }
    }

    /// Asks GitHub for the latest release. A check the user did not ask for fails quietly and is tried again later.
    func check(userInitiated: Bool = true) async {
        guard state != .checking else { return }
        let previous = state
        state = .checking
        let saved = Self.savedRelease
        // Without the saved release an unchanged answer would say nothing.
        let etag = saved == nil ? nil : UserDefaults.standard.string(forKey: Self.etagKey)
        let outcome: ReleaseLookup.Outcome
        do {
            let (data, response) = try await URLSession.shared.data(for: ReleaseLookup.request(etag: etag))
            let http = response as? HTTPURLResponse
            outcome = ReleaseLookup.outcome(status: http?.statusCode ?? 0, data: data) { http?.value(forHTTPHeaderField: $0) }
        } catch {
            fail(error.localizedDescription, previous: previous, userInitiated: userInitiated)
            return
        }
        switch outcome {
        case .release(let release, let etag):
            UserDefaults.standard.set([release.version.description, release.page.absoluteString], forKey: Self.latestKey)
            UserDefaults.standard.set(etag, forKey: Self.etagKey)
            finish(with: release)
        case .unchanged:
            // Only sent with a saved release, so there is one.
            guard let saved else {
                fail(AppLocalization.string("update.error.unreadable"), previous: previous, userInitiated: userInitiated)
                return
            }
            finish(with: saved)
        case .rateLimited(let retryAt):
            let message = retryAt.map {
                AppLocalization.format("update.error.rateLimitedUntil", $0.formatted(date: .omitted, time: .shortened))
            } ?? AppLocalization.string("update.error.rateLimited")
            fail(message, previous: previous, userInitiated: userInitiated)
        case .failed(let status):
            fail(AppLocalization.format("update.error.status", status), previous: previous, userInitiated: userInitiated)
        case .unreadable:
            fail(AppLocalization.string("update.error.unreadable"), previous: previous, userInitiated: userInitiated)
        }
    }

    private func finish(with release: Release) {
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        lastChecked = now
        state = Self.isNewer(release.version) ? .available(release) : .upToDate
        installIfAutomatic()
    }

    private func fail(_ message: String, previous: State, userInitiated: Bool) {
        // A failed check should not hide an update found earlier, and one made in the background is not worth an error.
        if case .available = previous {
            state = previous
        } else if userInitiated {
            state = .failed(message)
        } else {
            state = previous == .checking ? .idle : previous
        }
        // The message may name a host, so the log only says that a check failed.
        AppLog.updates.notice("Update check failed (\(userInitiated ? "manual" : "automatic", privacy: .public))")
    }

    private static func isNewer(_ version: AppVersion) -> Bool {
        currentVersion.map { version > $0 } ?? false
    }
}
