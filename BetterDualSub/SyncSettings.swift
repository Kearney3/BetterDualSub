import AppKit
import Foundation

/// Where the playback position comes from.
extension SyncMode {
    static let storageKey = "syncMode"
    static var current: SyncMode { SyncMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto }
}

/// Which app's Now Playing clock drives the subtitles.
enum SyncTarget {
    static let key = "syncTargetBundleID"
    static let tvBundleID = "com.apple.TV"
    /// Follow whichever app is currently playing.
    static let anyApp = PlaybackTracker.anyApp
    private static let knownKey = "knownSyncApps"

    static var current: String { UserDefaults.standard.string(forKey: key) ?? tvBundleID }

    /// User-facing name of the chosen source.
    static var currentName: String {
        switch current {
        case tvBundleID: AppLocalization.string("sync.source.tv")
        case anyApp: AppLocalization.string("sync.status.anyPlayer")
        case let id: knownApps.first { $0.id == id }?.name ?? id
        }
    }

    static var knownApps: [SyncApp] {
        guard let data = UserDefaults.standard.data(forKey: knownKey),
              let apps = try? JSONDecoder().decode([SyncApp].self, from: data) else { return [] }
        return apps
    }

    /// Apps that have reported playback plus the apps running now, so a player can be chosen before it first plays.
    static var selectableApps: [SyncApp] {
        var apps = knownApps.filter { $0.id != tvBundleID }
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let id = running.bundleIdentifier, id != tvBundleID, id != Bundle.main.bundleIdentifier,
                  !apps.contains(where: { $0.id == id }) else { continue }
            apps.append(SyncApp(id: id, name: running.localizedName ?? id))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func remember(_ app: SyncApp) {
        var apps = knownApps
        guard !apps.contains(where: { $0.id == app.id }) else { return }
        apps.append(app)
        if let data = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(data, forKey: knownKey) }
    }

}

extension SyncStatus {
    var title: String {
        switch self {
        case .manual: AppLocalization.string("sync.status.manual")
        case .following(let app, let playing):
            AppLocalization.format("sync.status.following", app) + " · "
                + AppLocalization.string(playing ? "sync.status.playing" : "sync.status.paused")
        case .waiting: AppLocalization.format("sync.status.waiting", SyncTarget.currentName)
        case .connecting: AppLocalization.string("sync.status.connecting")
        case .disconnected: AppLocalization.string("sync.status.disconnected")
        }
    }

    /// What the user can do about it, if anything.
    var help: String? {
        switch self {
        case .manual: AppLocalization.string("sync.status.manual.help")
        case .following: nil
        case .connecting: AppLocalization.string("sync.status.connecting.help")
        case .waiting(let other?): AppLocalization.format("sync.status.otherApp.help", other.name, SyncTarget.currentName)
        case .waiting(nil): AppLocalization.format("sync.status.waiting.help", SyncTarget.currentName)
        case .disconnected: AppLocalization.string("sync.status.disconnected.help")
        }
    }
}
