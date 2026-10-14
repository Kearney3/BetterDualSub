import SwiftUI
import AppKit

private enum ControlCenterPage: String, CaseIterable, Identifiable {
    case guide, movie, localPackage, localFile, bilingual, align, appearance, shortcuts, general

    var id: String { rawValue }
    static let subtitlePages: [Self] = [.movie, .localPackage, .localFile, .bilingual, .align]
    static let settingPages: [Self] = [.appearance, .shortcuts, .general]

    var titleKey: String {
        switch self {
        case .guide: "nav.guide"
        case .movie: "nav.movie"
        case .localPackage: "nav.localPackage"
        case .localFile: "nav.localFile"
        case .bilingual: "nav.bilingual"
        case .align: "nav.align"
        case .appearance: "nav.appearance"
        case .shortcuts: "nav.shortcuts"
        case .general: "nav.general"
        }
    }

    var tint: Color {
        switch self {
        case .guide: .orange
        case .movie: .blue
        case .localPackage: .indigo
        case .localFile: .green
        case .bilingual: .purple
        case .align: .mint
        case .appearance: .pink
        case .shortcuts: .teal
        case .general: .gray
        }
    }

    var symbol: String {
        switch self {
        case .guide: "sparkles"
        case .movie: "link"
        case .localPackage: "film.stack"
        case .localFile: "doc.text"
        case .bilingual: "character.bubble"
        case .align: "scope"
        case .appearance: "textformat"
        case .shortcuts: "keyboard"
        case .general: "gearshape"
        }
    }
}

struct ControlCenterView: View {
    @AppStorage(AppLocalization.languagePreferenceKey) private var language = AppLocalization.defaultLanguage
    @SceneStorage("controlCenter.selectedPage") private var selectedPageValue = ControlCenterPage.guide.rawValue
    @State private var searchText = ""

    private var selectedPage: ControlCenterPage {
        ControlCenterPage(rawValue: selectedPageValue) ?? .guide
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
                if matches(.guide) {
                    Section("nav.section.start") { pageRow(.guide) }
                }
                if ControlCenterPage.subtitlePages.contains(where: matches) {
                    Section("nav.section.subtitles") {
                        ForEach(ControlCenterPage.subtitlePages.filter(matches)) { pageRow($0) }
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
            if ControlCenterPage(rawValue: selectedPageValue) == nil {
                selectedPageValue = ControlCenterPage.guide.rawValue
            }
            if let page = AppDelegate.pendingControlCenterPage, ControlCenterPage(rawValue: page) != nil {
                selectedPageValue = page
                AppDelegate.pendingControlCenterPage = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToControlCenter)) { notification in
            if let page = notification.userInfo?["page"] as? String,
               ControlCenterPage(rawValue: page) != nil {
                selectedPageValue = page
            }
        }
        .onChange(of: language) { _, _ in
            NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
        }
    }

    @ViewBuilder
    private var activePage: some View {
        switch selectedPage {
        case .guide:
            GuideView()
        case .movie:
            MovieSubtitleDownloadView()
        case .localPackage:
            MovpkgSubtitleImportView()
        case .localFile:
            LocalSubtitleFileView()
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
    @EnvironmentObject private var manager: SubtitleManager
    @State private var showingCacheConfirmation = false
    @State private var cacheMessage = ""
    @State private var cacheError = false

    var body: some View {
        SettingsPage(descriptionKey: "general.language.description") {
            SettingsCard {
                SettingsRow(symbol: "play.rectangle.on.rectangle", tint: .green, titleKey: "sync.source.title", subtitleKey: "sync.source.help") {
                    Picker("sync.source.title", selection: $syncTarget) {
                        Text("sync.source.tv").tag(SyncTarget.tvBundleID)
                        Text("sync.source.any").tag(SyncTarget.anyApp)
                        let others = SyncTarget.selectableApps
                        ForEach(others) { app in Text(verbatim: app.name).tag(app.id) }
                        // Keep a saved choice selectable even if it was never seen in this list.
                        if syncTarget != SyncTarget.tvBundleID, syncTarget != SyncTarget.anyApp, !others.contains(where: { $0.id == syncTarget }) {
                            Text(verbatim: syncTarget).tag(syncTarget)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider()
                SyncStatusDetail()
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
