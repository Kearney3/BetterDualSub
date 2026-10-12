import SwiftUI
import AppKit

struct MovieSubtitleDownloadView: View {
    @EnvironmentObject private var manager: SubtitleManager
    @State private var link = ""
    @State private var dsid = ""
    @State private var versions: [MovieVersion] = []
    @State private var selectedVersion = ""
    @State private var tracks: [MovieSubtitleTrack] = []
    @State private var primaryID = ""
    @State private var secondaryID = ""
    @State private var busy = false
    @State private var status = ""
    @State private var failure = ""
    @State private var cacheFolder: URL?
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var downloader = MovieSubtitleDownloader()

    private var movie: MovieVersion? { versions.first { $0.id == selectedVersion } }

    var body: some View {
        SettingsPage(descriptionKey: "download.description") {
            SettingsCard(titleKey: "download.step.link") {
                HStack {
                    TextField("https://tv.apple.com/us/movie/…", text: $link)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("download.url")
                        .onSubmit { lookup() }
                    Button("download.find", action: lookup)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                DisclosureGroup("download.account.section") {
                    VStack(alignment: .leading, spacing: 6) {
                        SecureField("download.account.field", text: $dsid).textFieldStyle(.roundedBorder).disabled(busy)
                        SettingsHint(key: "download.account.help")
                    }.padding(.top, 6)
                }
                if !versions.isEmpty {
                    Divider()
                    HStack {
                        Picker("download.version", selection: $selectedVersion) {
                            ForEach(versions) { movie in Text(movie.label).tag(movie.id) }
                        }
                        Button("download.loadTracks", action: loadTracks).disabled(busy)
                    }.disabled(busy)
                }
            }
            if !tracks.isEmpty {
                SettingsCard(titleKey: "download.step.tracks") {
                    Picker("download.primary", selection: $primaryID) {
                        ForEach(tracks) { Text($0.label).tag($0.id) }
                    }.disabled(busy)
                    Picker("download.secondary", selection: $secondaryID) {
                        Text("download.noSecondary").tag("")
                        ForEach(tracks) { Text($0.label).tag($0.id) }
                    }.disabled(busy)
                    SettingsHint(key: "download.tracks.help")
                    HStack {
                        Button("download.action") { download(show: true) }
                            .buttonStyle(.borderedProminent)
                        Button("download.saveOnly") { download(show: false) }
                    }
                    .disabled(busy || primaryID.isEmpty || primaryID == secondaryID)
                }
            }
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status)
                    Spacer()
                    Button("common.cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
            } else if !status.isEmpty { StatusLine(text: status) }
            if !failure.isEmpty { StatusLine(text: failure, isError: true) }
            LoadedSubtitleCard {
                Text(AppLocalization.format("download.videoTime", manager.debugTimeStr)).monospacedDigit()
                    .font(.caption).foregroundStyle(.secondary)
                if let cacheFolder {
                    Button("download.openFolder") { NSWorkspace.shared.open(cacheFolder) }
                }
            }
        }
        .frame(minWidth: 560)
        .onChange(of: link) { _, _ in
            cancel()
            versions = []
            tracks = []
            selectedVersion = ""
            failure = ""
            status = ""
        }
        .onChange(of: selectedVersion) { _, _ in
            if !busy { tracks = []; primaryID = ""; secondaryID = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in
            status = ""
            failure = ""
        }
        .onDisappear { cancel(); dsid = "" }
    }

    private func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        if busy { status = AppLocalization.string("download.status.cancelled") }
        busy = false
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        failure = ""
        busy = true
        let token = UUID()
        generation = token
        operation = Task { @MainActor in
            do { try await action() }
            catch {
                guard generation == token else { return }
                if !Task.isCancelled { failure = error.localizedDescription; status = "" }
            }
            guard generation == token else { return }
            busy = false
            operation = nil
        }
    }

    private func setTracks(_ available: [MovieSubtitleTrack]) {
        tracks = available
        let full = available.filter { !$0.forced }
        let first = full.first { $0.language.lowercased().hasPrefix("en") } ?? full.first ?? available.first!
        primaryID = first.id
        secondaryID = full.first { $0.id != first.id && ($0.language.lowercased().hasPrefix("zh") || $0.language.lowercased().hasPrefix("cmn")) }?.id ?? ""
    }

    private func lookup() {
        run {
            let page = try MoviePage(link)
            versions = []; tracks = []
            status = AppLocalization.string("download.status.loadingMovie")
            let found = try await downloader.versions(for: page)
            try Task.checkCancellation()
            versions = found
            selectedVersion = found[0].id
            status = AppLocalization.string("download.status.loadingTracks")
            let available = try await downloader.tracks(for: found[0], dsid: dsid)
            try Task.checkCancellation()
            setTracks(available)
            status = AppLocalization.format("download.status.foundChoose", available.count)
        }
    }

    private func loadTracks() {
        guard let movie else { return }
        run {
            tracks = []
            status = AppLocalization.string("download.status.loadingTracks")
            let available = try await downloader.tracks(for: movie, dsid: dsid)
            try Task.checkCancellation()
            setTracks(available)
            status = AppLocalization.format("download.status.found", available.count)
        }
    }

    private func download(show: Bool) {
        guard let movie, let first = tracks.first(where: { $0.id == primaryID }), primaryID != secondaryID else { return }
        let selected = [first] + tracks.filter { $0.id == secondaryID }
        var exportFolder: URL?
        if !show {
            let panel = NSOpenPanel()
            panel.prompt = AppLocalization.string("download.savePrompt")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Subtitles", isDirectory: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            exportFolder = url
        }
        run {
            var documents: [SubtitleDocument] = []
            let progressGeneration = generation
            for (index, track) in selected.enumerated() {
                status = AppLocalization.format("download.status.downloading", track.language, index + 1, selected.count)
                let document = try await downloader.download(track) { completed, total in
                    await MainActor.run {
                        if generation == progressGeneration && busy {
                            status = AppLocalization.format("download.status.segments", track.language, completed, total)
                        }
                    }
                }
                try Task.checkCancellation()
                documents.append(document)
            }
            if let exportFolder {
                let name = movie.title.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == " " }
                    .trimmingCharacters(in: .whitespaces)
                for (document, track) in zip(documents, selected) {
                    let language = track.language.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(40)
                    try document.srt.write(to: exportFolder.appendingPathComponent("\(name.isEmpty ? "subtitle" : name).\(language).srt"),
                                           atomically: true, encoding: .utf8)
                }
                cacheFolder = exportFolder
                status = AppLocalization.format("download.status.saved", documents.count)
                return
            }
            let folder = try SubtitleCache.save(documents, tracks: selected, movie: movie)
            manager.load(primary: documents[0], secondary: documents.count > 1 ? documents[1] : nil,
                         title: movie.title, names: selected.map(\.label))
            cacheFolder = folder
            status = AppLocalization.string("download.status.loaded")
        }
    }
}

nonisolated enum SubtitleCache {
    static func root() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("BetterDualSub/Subtitles", isDirectory: true)
    }

    static func save(_ documents: [SubtitleDocument], tracks: [MovieSubtitleTrack], movie: MovieVersion) throws -> URL {
        let safeID = movie.id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(80)
        let folder = try root().appendingPathComponent("\(safeID)/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for (index, pair) in zip(documents, tracks).enumerated() {
                try Task.checkCancellation()
                let language = pair.1.language.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(40)
                try pair.0.srt.write(to: folder.appendingPathComponent("\(index + 1)-\(language).srt"), atomically: true, encoding: .utf8)
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }
}
