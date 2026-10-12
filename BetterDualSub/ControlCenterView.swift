import SwiftUI
import AppKit

private enum ControlCenterPage: String, CaseIterable, Identifiable {
    case guide, movie, localPackage, localFile, bilingual, align, appearance, shortcuts, general

    var id: String { rawValue }

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
    @State private var sidebarVisible = true

    private var selectedPage: ControlCenterPage {
        ControlCenterPage(rawValue: selectedPageValue) ?? .guide
    }

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(max(geometry.size.width * 0.23, 210), 270)

            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar
                        .frame(width: sidebarWidth)
                    Divider()
                }

                VStack(spacing: 0) {
                    detailHeader
                    activePage
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 920, minHeight: 620)
        .environment(\.locale, Locale(identifier: language))
        .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
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

    private var detailHeader: some View {
        HStack(spacing: 16) {
            Button {
                sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey(sidebarVisible ? "nav.hideSidebar" : "nav.showSidebar")))

            Text(LocalizedStringKey(selectedPage.titleKey))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(height: 64)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("nav.search", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(Text("nav.search"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if matches(.guide) {
                        sidebarSection("nav.section.start") {
                            pageRow(.guide)
                        }
                    }
                    if matches(.movie) || matches(.localPackage) || matches(.localFile) || matches(.bilingual) || matches(.align) {
                        sidebarSection("nav.section.subtitles") {
                            pageRow(.movie)
                            pageRow(.localPackage)
                            pageRow(.localFile)
                            pageRow(.bilingual)
                            pageRow(.align)
                        }
                    }
                    if matches(.appearance) || matches(.shortcuts) || matches(.general) {
                        sidebarSection("nav.section.settings") {
                            pageRow(.appearance)
                            pageRow(.shortcuts)
                            pageRow(.general)
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
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

    @ViewBuilder
    private func pageRow(_ page: ControlCenterPage) -> some View {
        if matches(page) {
            Button {
                selectedPageValue = page.rawValue
            } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: page.symbol, tint: page.tint, size: 26)
                    Text(LocalizedStringKey(page.titleKey))
                        .fontWeight(selectedPage == page ? .semibold : .regular)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if selectedPage == page {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.22))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help(AppLocalization.string(page.titleKey))
        }
    }

    private func matches(_ page: ControlCenterPage) -> Bool {
        searchText.isEmpty || AppLocalization.string(page.titleKey).localizedCaseInsensitiveContains(searchText)
    }

    private func sidebarSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            content()
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppLocalization.languagePreferenceKey) private var language = AppLocalization.defaultLanguage
    @AppStorage("showStatusBarItem") private var showStatusBarItem = true
    @AppStorage(SyncMode.storageKey) private var syncMode = SyncMode.auto.rawValue
    @AppStorage(SyncTarget.key) private var syncTarget = SyncTarget.tvBundleID
    @EnvironmentObject private var manager: SubtitleManager

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
                Text(manager.syncedAppName.map {
                        AppLocalization.format("sync.source.current", $0)
                            + " · " + manager.debugTimeStr + (manager.isPlaying ? " ▶︎" : " ⏸︎")
                    }
                     ?? AppLocalization.string("sync.source.none"))
                    .font(.caption).foregroundStyle(.secondary)
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
        }
        .onChange(of: showStatusBarItem) { _, _ in
            NotificationCenter.default.post(name: .statusBarVisibilityChanged, object: nil)
        }
    }
}
