import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MovpkgSubtitleImportView: View {
    @EnvironmentObject private var manager: SubtitleManager
    @State fileprivate var packageURL: URL?
    @State fileprivate var tracks: [LocalSubtitleTrack] = []
    @State fileprivate var primaryID = ""
    @State fileprivate var secondaryID = ""
    @State fileprivate var usePackageTimeline = false
    @State fileprivate var outputFolder: URL?
    @State fileprivate var status = AppLocalization.string("movpkg.panelMessage")
    @State fileprivate var error = ""

    fileprivate var primary: LocalSubtitleTrack? { tracks.first { $0.id == primaryID } }

    var body: some View {
        SettingsPage(descriptionKey: "movpkg.description") {
            SettingsCard(titleKey: "movpkg.chooseTitle") {
                HStack {
                    Button("movpkg.choose", action: choosePackage)
                    if let packageURL { Text(packageURL.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                }
                if tracks.isEmpty { SettingsHint(key: "movpkg.shortcutHint") }
            }
            if !tracks.isEmpty {
                SettingsCard {
                    Text(AppLocalization.format("movpkg.tracksAvailable", tracks.count)).font(.headline)
                    Picker("download.primary", selection: $primaryID) {
                        ForEach(tracks) { Text($0.label).tag($0.id) }
                    }
                    Picker("download.secondary", selection: $secondaryID) {
                        Text("download.noSecondary").tag("")
                        ForEach(tracks) { Text($0.label).tag($0.id) }
                    }
                    Divider()
                    Picker("movpkg.timeline.section", selection: $usePackageTimeline) {
                        Text("movpkg.timeline.episode").tag(false)
                        Text("movpkg.timeline.package").tag(true)
                    }.pickerStyle(.segmented)
                    SettingsHint(key: usePackageTimeline ? "movpkg.timeline.packageHelp" : "movpkg.timeline.episodeHelp")
                    Button("movpkg.extract", action: extract)
                        .buttonStyle(.borderedProminent)
                        .disabled(primaryID.isEmpty || primaryID == secondaryID)
                    Divider()
                    HStack {
                        Button("movpkg.exportTracks", action: exportTracks)
                            .disabled(primaryID.isEmpty || primaryID == secondaryID)
                    }
                    SettingsHint(key: "movpkg.exportHelp")
                }
            }
            if !status.isEmpty { StatusLine(text: status) }
            if !error.isEmpty { StatusLine(text: error, isError: true) }
            LoadedSubtitleCard {
                if let outputFolder {
                    Button("movpkg.openFolder") { NSWorkspace.shared.open(outputFolder) }
                }
                SettingsHint(key: "movpkg.shortcutHint")
            }
        }
        .frame(minWidth: 560)
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in
            error = ""
            status = packageURL == nil
                ? AppLocalization.string("movpkg.panelMessage")
                : AppLocalization.format("movpkg.status.read", tracks.count)
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("movpkg.panelTitle")
        panel.message = AppLocalization.string("movpkg.chooseTitle")
        panel.prompt = AppLocalization.string("movpkg.readTracks")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // .movpkg has no registered package UTI, so macOS treats it as a plain folder and
        // any content-type filter greys it out. Leave the panel unfiltered; inspect()
        // validates the extension and package structure after selection.
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Videos/Media.localized/TV Shows", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        packageURL = nil
        tracks = []
        primaryID = ""
        secondaryID = ""
        do {
            let available = try MovpkgSubtitleExtractor.inspect(url)
            packageURL = url
            tracks = available
            primaryID = available.first(where: { !$0.forced && !$0.sdh && $0.language.lowercased().hasPrefix("en") })?.id
                ?? available.first(where: { !$0.forced && $0.language.lowercased().hasPrefix("en") })?.id ?? available[0].id
            secondaryID = available.first(where: {
                !$0.forced && !$0.sdh && $0.id != primaryID
                    && ($0.language.lowercased().hasPrefix("zh") || $0.language.lowercased().hasPrefix("cmn"))
            })?.id ?? ""
            status = AppLocalization.format("movpkg.status.read", available.count)
            error = ""
            outputFolder = nil
        } catch {
            self.error = error.localizedDescription
            status = AppLocalization.string("movpkg.status.readFailed")
        }
    }

    private func extract() {
        guard let packageURL, let primary,
              secondaryID.isEmpty || secondaryID != primaryID else { return }
        do {
            let selected = [primary] + tracks.filter { $0.id == secondaryID }
            let documents = try selected.map { try MovpkgSubtitleExtractor.document(for: $0, packageTimeline: usePackageTimeline) }
            let folder = try LocalSubtitleCache.save(documents, tracks: selected, package: packageURL,
                                                     packageTimeline: usePackageTimeline)
            manager.load(primary: documents[0], secondary: documents.count > 1 ? documents[1] : nil,
                         title: packageURL.deletingPathExtension().lastPathComponent, names: selected.map(\.label))
            outputFolder = folder
            status = AppLocalization.format("movpkg.status.extracted",
                                            documents.map(\.items.count).map(String.init).joined(separator: " + "))
            error = ""
        } catch {
            self.error = error.localizedDescription
            status = AppLocalization.string("movpkg.status.extractFailed")
        }
    }
}

extension MovpkgSubtitleImportView {
    private func exportTracks() {
        guard let packageURL, let primary else { return }
        let panel = NSOpenPanel()
        panel.prompt = AppLocalization.string("movpkg.exportPrompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = LocalSubtitleCache.defaultFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let selected = [primary] + tracks.filter { $0.id == secondaryID }
            let documents = try selected.map { try MovpkgSubtitleExtractor.document(for: $0, packageTimeline: usePackageTimeline) }
            let base = LocalSubtitleCache.basename(packageURL)
            for (index, pair) in zip(documents, selected).enumerated() {
                let name = base + LocalSubtitleCache.suffix(pair.1, index: index, packageTimeline: usePackageTimeline) + ".srt"
                try pair.0.srt.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            outputFolder = folder
            status = AppLocalization.format("movpkg.status.exported", selected.count)
            error = ""
        } catch {
            self.error = error.localizedDescription
            status = AppLocalization.string("movpkg.status.exportFailed")
        }
    }
}

private enum LocalSubtitleCache {
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Subtitles", isDirectory: true)
    }

    static func basename(_ package: URL) -> String {
        package.deletingPathExtension().lastPathComponent
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func suffix(_ track: LocalSubtitleTrack, index: Int, packageTimeline: Bool) -> String {
        let language = track.language.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return "-\(index + 1)-\(language)\(track.sdh ? "-SDH" : "")-\(packageTimeline ? "package" : "episode")"
    }

    static func save(_ documents: [SubtitleDocument], tracks: [LocalSubtitleTrack], package: URL,
                     packageTimeline: Bool) throws -> URL {
        let basename = basename(package)
        let folder = defaultFolder.appendingPathComponent("\(basename)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for (index, pair) in zip(documents, tracks).enumerated() {
                try pair.0.srt.write(to: folder.appendingPathComponent(basename + suffix(pair.1, index: index, packageTimeline: packageTimeline) + ".srt"),
                                     atomically: true, encoding: .utf8)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }
}
