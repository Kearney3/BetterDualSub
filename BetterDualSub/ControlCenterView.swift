import SwiftUI
import AppKit

private enum ControlCenterPage: String, CaseIterable, Identifiable {
    case nowPlaying, load, recent, align, bilingual, appearance, shortcuts, general

    var id: String { rawValue }
    static let subtitlePages: [Self] = [.nowPlaying, .load, .recent]
    static let toolPages: [Self] = [.align, .bilingual]
    static let settingPages: [Self] = [.appearance, .shortcuts, .general]

    /// Resolves a page name, including the names of pages that were merged: the guide became Now Playing,
    /// and the three loading pages became sources of Load Subtitles.
    static func resolve(_ name: String) -> (page: Self, source: LoadSource?)? {
        switch name {
        case "guide": (.nowPlaying, nil)
        case "movie": (.load, .movie)
        case "localPackage": (.load, .episode)
        case "localFile": (.load, .file)
        default: Self(rawValue: name).map { ($0, nil) }
        }
    }

    var titleKey: String {
        switch self {
        case .nowPlaying: "nav.nowPlaying"
        case .load: "nav.load"
        case .recent: "recent.title"
        case .align: "nav.align"
        case .bilingual: "nav.bilingual"
        case .appearance: "nav.appearance"
        case .shortcuts: "nav.shortcuts"
        case .general: "nav.general"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: "play.rectangle"
        case .load: "square.and.arrow.down"
        case .recent: "clock.arrow.circlepath"
        case .align: "scope"
        case .bilingual: "character.bubble"
        case .appearance: "textformat"
        case .shortcuts: "keyboard"
        case .general: "gearshape"
        }
    }
}

struct ControlCenterView: View {
    @AppStorage(AppLocalization.languagePreferenceKey) private var language = AppLocalization.defaultLanguage
    @SceneStorage("controlCenter.selectedPage") private var selectedPageValue = ControlCenterPage.nowPlaying.rawValue
    @AppStorage(LoadSource.storageKey) private var loadSource = LoadSource.file
    @EnvironmentObject private var manager: SubtitleManager
    @State private var searchText = ""

    private var selectedPage: ControlCenterPage {
        ControlCenterPage.resolve(selectedPageValue)?.page ?? .nowPlaying
    }

    private var selection: Binding<ControlCenterPage?> {
        Binding(
            get: { selectedPage },
            set: { if let page = $0 { selectedPageValue = page.rawValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                if ControlCenterPage.subtitlePages.contains(where: matches) {
                    Section("nav.section.subtitles") {
                        ForEach(ControlCenterPage.subtitlePages.filter(matches)) { pageRow($0) }
                    }
                }
                if ControlCenterPage.toolPages.contains(where: matches) {
                    Section("nav.section.tools") {
                        ForEach(ControlCenterPage.toolPages.filter(matches)) { pageRow($0) }
                    }
                }
                if ControlCenterPage.settingPages.contains(where: matches) {
                    Section("nav.section.settings") {
                        ForEach(ControlCenterPage.settingPages.filter(matches)) { pageRow($0) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
        } detail: {
            activePage
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(LocalizedStringKey(selectedPage.titleKey))
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "nav.search")
        .frame(minWidth: 920, minHeight: 620)
        .environment(\.locale, Locale(identifier: language))
        .onAppear {
            navigate(to: selectedPageValue)
            if let page = AppDelegate.pendingControlCenterPage {
                navigate(to: page)
                AppDelegate.pendingControlCenterPage = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToControlCenter)) { notification in
            if let page = notification.userInfo?["page"] as? String { navigate(to: page) }
        }
        .onChange(of: manager.loadID) { _, _ in
            // Whatever the source, newly loaded subtitles are looked after on Now Playing.
            if selectedPage == .load { selectedPageValue = ControlCenterPage.nowPlaying.rawValue }
        }
        .onChange(of: language) { _, _ in
            NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
        }
    }

    /// Shows `name` (a page, or a merged page's old name), choosing its loading source if it has one.
    private func navigate(to name: String) {
        guard let target = ControlCenterPage.resolve(name) else {
            selectedPageValue = ControlCenterPage.nowPlaying.rawValue
            return
        }
        if let source = target.source { loadSource = source }
        selectedPageValue = target.page.rawValue
    }

    @ViewBuilder
    private var activePage: some View {
        switch selectedPage {
        case .nowPlaying:
            NowPlayingView()
        case .load:
            LoadSubtitlesView()
        case .recent:
            SettingsPage {
                RecentWatchingCard()
                if manager.recentSessions.isEmpty && manager.historyError == nil { SettingsHint(key: "recent.empty") }
            }
        case .bilingual:
            BilingualExportView()
        case .align:
            SubtitleAlignView()
        case .appearance:
            SubtitleAppearanceView()
        case .shortcuts:
            ShortcutSettingsView()
        case .general:
            GeneralSettingsView()
        }
    }

    private func pageRow(_ page: ControlCenterPage) -> some View {
        Label(LocalizedStringKey(page.titleKey), systemImage: page.symbol)
            .tag(page)
            .help(AppLocalization.string(page.titleKey))
    }

    private func matches(_ page: ControlCenterPage) -> Bool {
        searchText.isEmpty || AppLocalization.string(page.titleKey).localizedCaseInsensitiveContains(searchText)
    }

}

private struct GeneralSettingsView: View {
    @AppStorage(AppLocalization.languagePreferenceKey) private var language = AppLocalization.defaultLanguage
    @AppStorage("showStatusBarItem") private var showStatusBarItem = true
    @AppStorage(SyncMode.storageKey) private var syncMode = SyncMode.auto.rawValue
    @AppStorage(SyncTarget.key) private var syncTarget = SyncTarget.tvBundleID
    @AppStorage(UpdateChecker.autoCheckKey) private var checkForUpdates = true
    @EnvironmentObject private var manager: SubtitleManager
    @State private var showingCacheConfirmation = false
    @State private var cacheMessage = ""
    @State private var cacheError = false

    var body: some View {
        SettingsPage(descriptionKey: "general.language.description") {
            SettingsCard {
                SettingsRow(symbol: "play.rectangle.on.rectangle", tint: .green, titleKey: "sync.source.title", subtitleKey: "sync.source.help") {
                    Picker("sync.source.title", selection: $syncTarget) {
                        syncAppLabel(AppLocalization.string("sync.source.tv"), bundleID: SyncTarget.tvBundleID)
                            .tag(SyncTarget.tvBundleID)
                        Label("sync.source.any", systemImage: "play.rectangle.on.rectangle").tag(SyncTarget.anyApp)
                        let others = SyncTarget.selectableApps
                        ForEach(others) { app in syncAppLabel(app.name, bundleID: app.id).tag(app.id) }
                        // Keep a saved choice selectable even if it was never seen in this list.
                        if syncTarget != SyncTarget.tvBundleID, syncTarget != SyncTarget.anyApp, !others.contains(where: { $0.id == syncTarget }) {
                            syncAppLabel(syncTarget, bundleID: syncTarget).tag(syncTarget)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider()
                SyncStatusDetail(showsDiagnostics: true)
            }
            SettingsCard {
                SettingsRow(symbol: "timer", tint: .orange, titleKey: "sync.mode.title", subtitleKey: "sync.mode.help") {
                    Picker("sync.mode.title", selection: $syncMode) {
                        Text("sync.mode.auto").tag(SyncMode.auto.rawValue)
                        Text("sync.mode.manual").tag(SyncMode.manual.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            SettingsCard {
                SettingsRow(symbol: "globe", tint: .blue, titleKey: "general.language.picker") {
                    Picker("general.language.picker", selection: $language) {
                        Text("简体中文").tag("zh-Hans")
                        Text("English").tag("en")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            SettingsCard {
                SettingsRow(symbol: "menubar.rectangle", tint: .teal, titleKey: "general.menuBar.showIcon",
                            subtitleKey: "general.menuBar.help") {
                    Toggle("general.menuBar.showIcon", isOn: $showStatusBarItem)
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            SubtitleScreenSettings()
            SettingsCard {
                Button("ready.reset") {
                    UserDefaults.standard.set(false, forKey: "viewingSetupCompleted")
                    UserDefaults.standard.set(false, forKey: "subtitleVisibilityConfirmed")
                    showControlCenterPage("nowPlaying")
                }
            }
            SettingsCard {
                SettingsRow(symbol: "folder", tint: .indigo, titleKey: "general.cache.title",
                            subtitleKey: "general.cache.help") {
                    HStack {
                        Button("general.cache.open") {
                            if let folder = try? SubtitleCache.root(), FileManager.default.fileExists(atPath: folder.path) {
                                NSWorkspace.shared.open(folder)
                            }
                        }
                        Button("general.cache.clear") { showingCacheConfirmation = true }
                    }
                }
                if !cacheMessage.isEmpty { StatusLine(text: cacheMessage, isError: cacheError) }
            }
            SettingsCard {
                SettingsRow(symbol: "arrow.down.app", tint: .blue, titleKey: "update.auto", subtitleKey: "update.help") {
                    Toggle("update.auto", isOn: $checkForUpdates).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                UpdateStatusView()
            }
        }
        .confirmationDialog("general.cache.confirm", isPresented: $showingCacheConfirmation) {
            Button("general.cache.clear", role: .destructive) { clearCache() }
        }
        .onChange(of: showStatusBarItem) { _, _ in
            NotificationCenter.default.post(name: .statusBarVisibilityChanged, object: nil)
        }
        .onChange(of: syncTarget) { _, _ in
            manager.syncTargetDidChange()
        }
        .onChange(of: syncMode) { _, value in
            manager.setSyncMode(SyncMode(rawValue: value) ?? .auto)
        }
    }

    private func syncAppLabel(_ name: String, bundleID: String) -> some View {
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        return Label {
            Text(verbatim: name)
        } icon: {
            if let icon {
                Image(nsImage: icon).renderingMode(.original).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app")
            }
        }
    }

    private func clearCache() {
        Task {
            do {
                let removed = try await Task.detached(priority: .userInitiated) {
                    let folder = try SubtitleCache.root()
                    guard FileManager.default.fileExists(atPath: folder.path) else { return false }
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: folder, resultingItemURL: &trashed)
                    return true
                }.value
                cacheError = false
                cacheMessage = AppLocalization.string(removed ? "general.cache.cleared" : "general.cache.empty")
            } catch {
                cacheError = true
                cacheMessage = error.localizedDescription
            }
        }
    }
}

/// The running version, the result of the last update check, and how to get a newer version.
private struct UpdateStatusView: View {
    @ObservedObject private var updater = UpdateChecker.shared

    private var current: String { UpdateChecker.currentVersion?.description ?? Bundle.main.appVersion }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                status
                Spacer()
                Button("update.check") { Task { await updater.check() } }
                    .disabled(updater.state == .checking)
            }
            if let release = updater.available {
                if UpdateChecker.installedWithHomebrew {
                    SettingsHint(key: "update.brew.help")
                    HStack {
                        Text(verbatim: UpdateChecker.brewCommand)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("update.copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(UpdateChecker.brewCommand, forType: .string)
                        }
                        Button("update.notes") { NSWorkspace.shared.open(release.page) }
                    }
                    .controlSize(.small)
                } else {
                    Button("update.download") { NSWorkspace.shared.open(release.page) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updater.state {
        case .idle:
            Text(AppLocalization.format("update.current", current)).foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
            Text("update.checking").foregroundStyle(.secondary)
        case .upToDate:
            Text(AppLocalization.format("update.upToDate", current)).foregroundStyle(.secondary)
        case .available(let release):
            Label(AppLocalization.format("update.available", release.version.description, current),
                  systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case .failed(let message):
            StatusLine(text: AppLocalization.format("update.failed", message), isError: true)
        }
    }
}
