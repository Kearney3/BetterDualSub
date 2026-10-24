import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Extracts subtitle tracks from an Apple TV .movpkg or from a video file with embedded text subtitles (.mkv, .mp4 …).
struct MovpkgSubtitleImportView: View {
    @Binding var inputURLs: [URL]

    init(inputURLs: Binding<[URL]> = .constant([])) { self._inputURLs = inputURLs }
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
    @AppStorage("preferredPrimarySubtitleLanguage") private var preferredPrimary = "en"
    @AppStorage("preferredSecondarySubtitleLanguage") private var preferredSecondary = "zh"
    /// Track 2 is made by translating Track 1 after extraction, rather than taken from the package.
    @AppStorage("movpkgTranslateSecondary") private var translateSecondary = false
    /// Folder of the last package or video chosen, where the next panel opens.
    @AppStorage("localVideoFolder") private var lastFolder = ""

    /// Picker tag of "translate Track 1" for Track 2.
    private static let translateTag = "\u{0}translate"

    fileprivate var primary: LocalSubtitleTrack? { tracks.first { $0.id == primaryID } }

    /// The tracks come from a video file rather than a .movpkg: one timeline, and all tracks are read in one pass.
    private var isVideo: Bool {
        packageURL.map { VideoSubtitleExtractor.fileExtensions.contains($0.pathExtension.lowercased()) } ?? false
    }

    private var readStatus: String {
        AppLocalization.format(isVideo ? "movpkg.status.readVideo" : "movpkg.status.read", tracks.count)
    }

    /// The package track chosen for Track 2, or "" for none (also when Track 2 is to be translated).
    private var secondaryTrackID: String { secondaryID == Self.translateTag ? "" : secondaryID }

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
                    Picker("download.primary", selection: Binding(get: { primaryID }, set: { id in
                        primaryID = id
                        if let track = tracks.first(where: { $0.id == id }) { preferredPrimary = track.language }
                    })) {
                        ForEach(tracks) { Text($0.label).tag($0.id) }
                    }.disabled(busy)
                    Picker("download.secondary", selection: Binding(get: { secondaryID }, set: { id in
                        secondaryID = id
                        translateSecondary = id == Self.translateTag
                        // Translating keeps the language Track 2 is otherwise taken in.
                        if !translateSecondary { preferredSecondary = tracks.first(where: { $0.id == id })?.language ?? "" }
                    })) {
                        Text("download.noSecondary").tag("")
                        Text("movpkg.secondary.translate").tag(Self.translateTag)
                        Divider()
                        ForEach(tracks) { Text($0.label).tag($0.id) }
                    }.disabled(busy)
                    if secondaryID == Self.translateTag { SettingsHint(key: "movpkg.secondary.translateHelp") }
                    Divider()
                    if !isVideo {
                        Picker("movpkg.timeline.section", selection: $usePackageTimeline) {
                            Text("movpkg.timeline.episode").tag(false)
                            Text("movpkg.timeline.package").tag(true)
                        }.pickerStyle(.segmented).disabled(busy)
                        SettingsHint(key: usePackageTimeline ? "movpkg.timeline.packageHelp" : "movpkg.timeline.episodeHelp")
                    }
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
            if let outputFolder, !busy {
                Button("movpkg.openFolder") { NSWorkspace.shared.open(outputFolder) }
            }
        }
        .frame(minWidth: 560)
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in
            error = ""
            status = packageURL == nil ? AppLocalization.string("movpkg.panelMessage") : readStatus
        }
        .onDisappear(perform: cancel)
        .onAppear(perform: consumeInput)
        .onChange(of: inputURLs) { _, _ in consumeInput() }
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
        panel.directoryURL = lastFolder.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Videos/Media.localized/TV Shows", isDirectory: true)
            : URL(fileURLWithPath: lastFolder, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastFolder = url.deletingLastPathComponent().path
        inspect(url)
    }

    private func consumeInput() {
        guard case .package(let url) = SubtitleInput(urls: inputURLs) else { return }
        inputURLs = []
        cancel()
        inspect(url)
    }

    private func inspect(_ url: URL) {
        packageURL = nil
        tracks = []
        primaryID = ""
        secondaryID = ""
        run {
            status = AppLocalization.string("movpkg.status.inspecting")
            let available = VideoSubtitleExtractor.fileExtensions.contains(url.pathExtension.lowercased())
                ? try await VideoSubtitleExtractor.inspect(url)
                : try await background { try MovpkgSubtitleExtractor.inspect(url) }
            packageURL = url
            tracks = available
            primaryID = available.first(where: { !$0.forced && !$0.sdh && SubtitleLanguagePreference.matches($0.language, preferredPrimary) })?.id
                ?? available.first(where: { !$0.forced && SubtitleLanguagePreference.matches($0.language, preferredPrimary) })?.id
                ?? available.first(where: { !$0.forced && !$0.sdh })?.id ?? available.first(where: { !$0.forced })?.id ?? available[0].id
            secondaryID = translateSecondary ? Self.translateTag : preferredSecondary.isEmpty ? "" : available.first(where: {
                !$0.forced && !$0.sdh && $0.id != primaryID
                    && SubtitleLanguagePreference.matches($0.language, preferredSecondary)
            })?.id ?? ""
            status = readStatus
            error = ""
            outputFolder = nil
        }
    }

    private func extract() {
        guard let packageURL, let primary,
              secondaryID.isEmpty || secondaryID != primaryID else { return }
        let selected = [primary] + tracks.filter { $0.id == secondaryID }
        let packageTimeline = !isVideo && usePackageTimeline
        let timeline: Bool? = isVideo ? nil : packageTimeline
        let translate = secondaryID == Self.translateTag
        let secondaryTrackID = secondaryTrackID
        run {
            let (documents, extracted) = try await extractDocuments(selected, packageTimeline: packageTimeline)
            status = AppLocalization.string("movpkg.status.saving")
            let folder = try await background {
                try LocalSubtitleCache.save(documents, tracks: selected, package: packageURL, packageTimeline: timeline)
            }
            manager.load(primary: documents[0], secondary: documents.count > 1 ? documents[1] : nil,
                         title: packageURL.deletingPathExtension().lastPathComponent, names: selected.map(\.label),
                         sourceID: timeline.map { "package:\(packageURL.lastPathComponent):\($0)" } ?? "video:\(packageURL.lastPathComponent)",
                         packageTracks: PackageTrackChoice(tracks: tracks, packageTimeline: packageTimeline,
                                                           primaryID: primary.id, secondaryID: secondaryTrackID,
                                                           documents: extracted))
            if translate { SubtitleTranslator.shared.requestAutomaticStart(loadID: manager.loadID) }
            outputFolder = folder
            status = AppLocalization.format(translate ? "movpkg.status.extractedTranslating" : "movpkg.status.extracted",
                                            documents.map(\.items.count).map(String.init).joined(separator: " + "))
        }
    }
}

extension MovpkgSubtitleImportView {
    /// The documents of `selected`, in order, and every track extracted along the way: a video file is read once for
    /// all of its tracks, so later switches need no second pass.
    private func extractDocuments(_ selected: [LocalSubtitleTrack],
                                  packageTimeline: Bool) async throws -> ([SubtitleDocument], [String: SubtitleDocument]) {
        if isVideo {
            status = AppLocalization.string("movpkg.status.readingVideo")
            let all = try await VideoSubtitleExtractor.documents(for: tracks)
            let documents = try selected.map { track in
                guard let document = all[track.id] else { throw SubtitleError.message("error.subtitle.empty") }
                return document
            }
            return (documents, all)
        }
        var documents: [SubtitleDocument] = []
        for (index, track) in selected.enumerated() {
            status = AppLocalization.format("movpkg.status.progress", index + 1, selected.count)
            documents.append(try await background {
                try MovpkgSubtitleExtractor.document(for: track, packageTimeline: packageTimeline)
            })
        }
        return (documents, [:])
    }

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
        let packageTimeline = !isVideo && usePackageTimeline
        let timeline: Bool? = isVideo ? nil : packageTimeline
        run {
            let (documents, _) = try await extractDocuments(selected, packageTimeline: packageTimeline)
            status = AppLocalization.string("movpkg.status.saving")
            try await background {
                try LocalSubtitleCache.export(documents, tracks: selected, package: packageURL,
                                              packageTimeline: timeline, to: folder)
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

    /// `packageTimeline` is nil for a video file, which has only its own timeline.
    static func suffix(_ track: LocalSubtitleTrack, index: Int, packageTimeline: Bool?) -> String {
        let language = track.language.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return "-\(index + 1)-\(language)\(track.sdh ? "-SDH" : "")" + (packageTimeline.map { $0 ? "-package" : "-episode" } ?? "")
    }

    static func save(_ documents: [SubtitleDocument], tracks: [LocalSubtitleTrack], package: URL,
                     packageTimeline: Bool?) throws -> URL {
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
                       packageTimeline: Bool?, to folder: URL) throws {
        let base = basename(package)
        for (index, pair) in zip(documents, tracks).enumerated() {
            try Task.checkCancellation()
            let name = base + suffix(pair.1, index: index, packageTimeline: packageTimeline) + ".srt"
            try pair.0.srt.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try Task.checkCancellation()
    }
}
