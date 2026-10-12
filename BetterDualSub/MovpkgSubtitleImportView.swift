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
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()

    fileprivate var primary: LocalSubtitleTrack? { tracks.first { $0.id == primaryID } }

    var body: some View {
        SettingsPage(descriptionKey: "movpkg.description") {
            SettingsCard(titleKey: "movpkg.chooseTitle") {
                HStack {
                    Button("movpkg.choose", action: choosePackage).disabled(busy)
                    if let packageURL { Text(packageURL.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                }
                if tracks.isEmpty { SettingsHint(key: "movpkg.shortcutHint") }
            }
            if !tracks.isEmpty {
                SettingsCard {
                    Text(AppLocalization.format("movpkg.tracksAvailable", tracks.count)).font(.headline)
                    Picker("download.primary", selection: $primaryID) {
                        ForEach(tracks) { Text($0.label).tag($0.id) }
                    }.disabled(busy)
                    Picker("download.secondary", selection: $secondaryID) {
                        Text("download.noSecondary").tag("")
                        ForEach(tracks) { Text($0.label).tag($0.id) }
                    }.disabled(busy)
                    Divider()
                    Picker("movpkg.timeline.section", selection: $usePackageTimeline) {
                        Text("movpkg.timeline.episode").tag(false)
                        Text("movpkg.timeline.package").tag(true)
                    }.pickerStyle(.segmented).disabled(busy)
                    SettingsHint(key: usePackageTimeline ? "movpkg.timeline.packageHelp" : "movpkg.timeline.episodeHelp")
                    Button("movpkg.extract", action: extract)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || primaryID.isEmpty || primaryID == secondaryID)
                    Divider()
                    HStack {
                        Button("movpkg.exportTracks", action: exportTracks)
                            .disabled(busy || primaryID.isEmpty || primaryID == secondaryID)
                    }
                    SettingsHint(key: "movpkg.exportHelp")
                }
            }
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status)
                    Spacer()
                    Button("common.cancel", action: cancel)
                }
            } else if !status.isEmpty { StatusLine(text: status) }
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
        .onDisappear(perform: cancel)
    }

    private func cancel() {
        if busy { status = AppLocalization.string("download.status.cancelled") }
        generation = UUID()
        operation?.cancel()
        operation = nil
        busy = false
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = ""
        let token = UUID()
        generation = token
        operation = Task { @MainActor in
            do { try await action() }
            catch {
                guard generation == token else { return }
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    status = ""
                }
            }
            guard generation == token else { return }
            busy = false
            operation = nil
        }
    }

    private func background<Result: Sendable>(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
        let worker = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
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
        run {
            status = AppLocalization.string("movpkg.status.inspecting")
            let available = try await background { try MovpkgSubtitleExtractor.inspect(url) }
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
        }
    }

    private func extract() {
        guard let packageURL, let primary,
              secondaryID.isEmpty || secondaryID != primaryID else { return }
        let selected = [primary] + tracks.filter { $0.id == secondaryID }
        let packageTimeline = usePackageTimeline
        run {
            var documents: [SubtitleDocument] = []
            for (index, track) in selected.enumerated() {
                status = AppLocalization.format("movpkg.status.progress", index + 1, selected.count)
                documents.append(try await background {
                    try MovpkgSubtitleExtractor.document(for: track, packageTimeline: packageTimeline)
                })
            }
            status = AppLocalization.string("movpkg.status.saving")
            let savedDocuments = documents
            let folder = try await background {
                try LocalSubtitleCache.save(savedDocuments, tracks: selected, package: packageURL,
                                            packageTimeline: packageTimeline)
            }
            manager.load(primary: documents[0], secondary: documents.count > 1 ? documents[1] : nil,
                         title: packageURL.deletingPathExtension().lastPathComponent, names: selected.map(\.label))
            outputFolder = folder
            status = AppLocalization.format("movpkg.status.extracted",
                                            documents.map(\.items.count).map(String.init).joined(separator: " + "))
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
        let selected = [primary] + tracks.filter { $0.id == secondaryID }
        let packageTimeline = usePackageTimeline
        run {
            var documents: [SubtitleDocument] = []
            for (index, track) in selected.enumerated() {
                status = AppLocalization.format("movpkg.status.progress", index + 1, selected.count)
                documents.append(try await background {
                    try MovpkgSubtitleExtractor.document(for: track, packageTimeline: packageTimeline)
                })
            }
            status = AppLocalization.string("movpkg.status.saving")
            let exportedDocuments = documents
            try await background {
                try LocalSubtitleCache.export(exportedDocuments, tracks: selected, package: packageURL,
                                              packageTimeline: packageTimeline, to: folder)
            }
            outputFolder = folder
            status = AppLocalization.format("movpkg.status.exported", selected.count)
        }
    }
}

private nonisolated enum LocalSubtitleCache {
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
        let folder = try SubtitleCache.root().appendingPathComponent("Local/\(basename)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for (index, pair) in zip(documents, tracks).enumerated() {
                try Task.checkCancellation()
                try pair.0.srt.write(to: folder.appendingPathComponent(basename + suffix(pair.1, index: index, packageTimeline: packageTimeline) + ".srt"),
                                     atomically: true, encoding: .utf8)
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    static func export(_ documents: [SubtitleDocument], tracks: [LocalSubtitleTrack], package: URL,
                       packageTimeline: Bool, to folder: URL) throws {
        let base = basename(package)
        for (index, pair) in zip(documents, tracks).enumerated() {
            try Task.checkCancellation()
            let name = base + suffix(pair.1, index: index, packageTimeline: packageTimeline) + ".srt"
            try pair.0.srt.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try Task.checkCancellation()
    }
}
