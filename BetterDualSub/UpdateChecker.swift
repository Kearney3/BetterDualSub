import Foundation
import Combine
import Sparkle

/// Looks up the latest GitHub release and tells the user when it is newer than the running app. Nothing is downloaded
/// until the user asks: Homebrew installs are upgraded with `brew`, others in the app through Sparkle.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let autoCheckKey = "checkForUpdates"
    static let brewCommand = "brew upgrade --cask betterdualsub"
    private static let lastCheckKey = "lastUpdateCheck"
    /// The newest release seen, as [version, page URL], so a found update is still offered after a relaunch.
    private static let latestKey = "latestRelease"
    private static let latestURL = URL(string: "https://api.github.com/repos/Kearney3/BetterDualSub/releases/latest")!
    private static let checkInterval: TimeInterval = 86_400

    struct Release: Equatable {
        let version: AppVersion
        let page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Sparkle only installs updates the user asks for; its own scheduled checks are off in Info.plist, and it is not
    /// started for Homebrew installs, which it must not replace behind `brew`'s back.
    private let sparkle = SPUStandardUpdaterController(startingUpdater: UpdateChecker.canInstallInApp,
                                                       updaterDelegate: nil, userDriverDelegate: nil)

    var available: Release? {
        if case .available(let release) = state { release } else { nil }
    }

    static var currentVersion: AppVersion? { AppVersion(Bundle.main.appVersion) }

    /// Installed with the Homebrew cask, so `brew` should do the upgrade.
    static var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/betterdualsub", "/usr/local/Caskroom/betterdualsub"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Not installed with Homebrew, and built with the release signing key (local builds are not), so the app can
    /// download and install updates itself.
    static var canInstallInApp: Bool {
        !installedWithHomebrew && !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
    }

    /// Shows Sparkle's update window, which downloads, verifies and installs the update, then relaunches.
    func installUpdate() {
        guard Self.canInstallInApp else { return }
        sparkle.checkForUpdates(nil)
    }

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.latestKey), saved.count == 2,
           let version = AppVersion(saved[0]), let page = URL(string: saved[1]), Self.isNewer(version) {
            state = .available(Release(version: version, page: page))
        }
    }

    /// At launch: checks when automatic checks are on and the last check is over a day old.
    func checkIfDue() {
        guard UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { await check() }
    }

    func check() async {
        guard state != .checking else { return }
        let previous = state
        state = .checking
        do {
            var request = URLRequest(url: Self.latestURL, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let version = AppVersion(release.tagName), let page = URL(string: release.htmlURL) else {
                throw URLError(.cannotParseResponse)
            }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            UserDefaults.standard.set([version.description, page.absoluteString], forKey: Self.latestKey)
            state = Self.isNewer(version) ? .available(Release(version: version, page: page)) : .upToDate
        } catch {
            // A failed check should not hide an update found earlier.
            if case .available = previous { state = previous } else { state = .failed(error.localizedDescription) }
        }
    }

    private static func isNewer(_ version: AppVersion) -> Bool {
        currentVersion.map { version > $0 } ?? false
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
