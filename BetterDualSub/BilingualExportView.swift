import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Standalone tool: lines up two subtitle files (or two sets of a season's files) and writes them as one bilingual
/// file or as two synced files, without loading anything for playback.
struct BilingualExportView: View {
    private enum Mode: String { case pair, season }

    @AppStorage("mergeMode") private var mode = Mode.pair
    @AppStorage("mergePattern") private var pattern = "{name}.bilingual"
    @AppStorage("mergeFolder") private var folderPath = ""
    @AppStorage("mergeExisting") private var existing = OutputNaming.ExistingFile.rename
    @AppStorage("mergeAutoDetect") private var autoDetect = true
    private var preferences = MergePreferences()

    @State private var primaryURL: URL?
    @State private var secondaryURL: URL?
    @State private var primaryFiles: [URL] = []
    @State private var secondaryFiles: [URL] = []
    @State private var options = BilingualMergeOptions()
    /// The first pair, read for the preview and offset detection.
    @State private var loaded: (primary: SubtitleDocument, secondary: SubtitleDocument)?
    @State private var detecting = false
    @State private var status = ""
    @State private var error = ""
    @State private var busy = false
    @State private var operation: Task<Void, Never>?

    private var pairing: (pairs: [(primary: URL, secondary: URL, key: EpisodeKey)], unmatchedPrimary: [URL], unmatchedSecondary: [URL]) {
        EpisodeKey.pair(primary: primaryFiles, secondary: secondaryFiles)
    }

    /// The files the preview shows: the chosen pair, or the first pair of the season.
    private var previewPair: (URL, URL)? {
        switch mode {
        case .pair: primaryURL.flatMap { first in secondaryURL.map { (first, $0) } }
        case .season: pairing.pairs.first.map { ($0.primary, $0.secondary) }
        }
    }

    var body: some View {
        SettingsPage(descriptionKey: "bilingual.description") {
            Picker("merge.mode", selection: $mode) {
                Text("merge.mode.pair").tag(Mode.pair)
                Text("merge.mode.season").tag(Mode.season)
            }
            .pickerStyle(.segmented).labelsHidden().disabled(busy)

            switch mode {
            case .pair: pairFiles
            case .season: seasonFiles
            }

            syncCard
            if let loaded { preview(loaded) }
            outputCard
        }
        .frame(minWidth: 560)
        .onAppear { options = preferences.options(offset: options.secondaryOffsetMs) }
        .onChange(of: options) { _, options in preferences.save(options) }
        .task(id: previewPair.map { [$0.0, $0.1] }) { await loadPreview() }
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in status = ""; error = "" }
        .onDisappear { operation?.cancel() }
    }

    private var syncCard: some View {
        let detect: (() -> Void)? = mode == .pair ? { detectOffset() } : nil
        return SettingsCard(titleKey: "merge.sync.title") {
            MergeOptionsSection(options: $options, showsDelay: mode == .pair || !autoDetect, detect: detect, detecting: detecting)
            if mode == .season {
                Toggle("merge.autoDetect", isOn: $autoDetect)
                SettingsHint(key: "merge.autoDetect.help")
            }
        }
        .disabled(busy)
    }

    private var outputCard: some View {
        let title: LocalizedStringKey = mode == .pair ? "bilingual.export" : "merge.exportSeason"
        let ready = mode == .pair ? previewPair != nil : !pairing.pairs.isEmpty
        let example = pairing.pairs.first.map { fileName(for: $0.primary) }
        return SettingsCard(titleKey: "merge.output.title") {
            if mode == .season {
                OutputOptionsSection(folderPath: $folderPath, pattern: $pattern, existing: $existing,
                                     example: example, showsPattern: options.layout == .combined)
                if options.layout == .separate { SettingsHint(key: "merge.separate.naming") }
            }
            HStack {
                Button(title, action: export)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !ready)
                if busy {
                    ProgressView().controlSize(.small)
                    Button("common.cancel") { operation?.cancel() }
                }
            }
            if !status.isEmpty { StatusLine(text: status) }
            if !error.isEmpty { StatusLine(text: error, isError: true) }
        }
    }

    // MARK: Files

    private var pairFiles: some View {
        SettingsCard {
            Text("bilingual.primary.title").font(.headline)
            SubtitleFileRow(url: $primaryURL, symbol: "text.bubble")
            HStack {
                Spacer()
                Button {
                    swap(&primaryURL, &secondaryURL)
                } label: { Label("localFile.swap", systemImage: "arrow.up.arrow.down") }
                .controlSize(.small).disabled(primaryURL == nil && secondaryURL == nil)
                Spacer()
            }
            Text("bilingual.secondary.title").font(.headline)
            SubtitleFileRow(url: $secondaryURL, symbol: "text.bubble.fill")
        }
        .disabled(busy)
    }

    @ViewBuilder
    private var seasonFiles: some View {
        SubtitleFileDropList(titleKey: "bilingual.primary.title", files: $primaryFiles, disabled: busy)
        SubtitleFileDropList(titleKey: "bilingual.secondary.title", files: $secondaryFiles, disabled: busy)
        if !primaryFiles.isEmpty || !secondaryFiles.isEmpty {
            let pairing = pairing
            SettingsCard(titleKey: "merge.pairs.title") {
                if pairing.pairs.isEmpty {
                    StatusLine(text: AppLocalization.string("merge.pairs.none"), isError: true)
                }
                ForEach(pairing.pairs, id: \.primary) { pair in
                    HStack(alignment: .top, spacing: 10) {
                        Text(verbatim: pair.key.label).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: pair.primary.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: pair.secondary.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        }
                    }
                }
                let unmatched = pairing.unmatchedPrimary + pairing.unmatchedSecondary
                if !unmatched.isEmpty {
                    StatusLine(text: AppLocalization.format("merge.pairs.unmatched", unmatched.count,
                                                            unmatched.map(\.lastPathComponent).joined(separator: ", ")), isError: true)
                }
            }
        }
    }

    // MARK: Preview

    private func preview(_ loaded: (primary: SubtitleDocument, secondary: SubtitleDocument)) -> some View {
        var lined = options
        if mode == .season, autoDetect { lined.secondaryOffsetMs = loaded.secondary.estimatedOffset(to: loaded.primary) ?? options.secondaryOffsetMs }
        let cues = (try? SubtitleDocument.bilingualCues(primary: loaded.primary, secondary: loaded.secondary,
                                                        secondaryOffsetMs: lined.secondaryOffsetMs, tolerance: lined.tolerance)) ?? []
        return SettingsCard(titleKey: "merge.preview.title") {
            if mode == .season, autoDetect {
                StatusLine(text: AppLocalization.format("merge.preview.detected", lined.secondaryOffsetMs))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(cues.prefix(500).enumerated()), id: \.offset) { _, cue in
                        HStack(alignment: .top, spacing: 10) {
                            Text(verbatim: ManualControlBar.format(cue.startMs)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                let lines = lined.secondaryOnTop && lined.layout == .combined
                                    ? [(cue.secondary, true), (cue.primary, false)] : [(cue.primary, false), (cue.secondary, true)]
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    if !line.0.isEmpty {
                                        Text(verbatim: SubtitleMarkup.plainText(line.0).replacingOccurrences(of: "\n", with: " "))
                                            .font(line.1 ? .callout : .body).foregroundStyle(line.1 ? .secondary : .primary)
                                    }
                                }
                            }
                            .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 8)
                    }
                }
            }
            .frame(height: 260)
            SettingsHint(key: "merge.preview.help")
        }
    }

    private func loadPreview() async {
        loaded = nil
        guard let (first, second) = previewPair else { return }
        do {
            let documents = try await SubtitleBackgroundWork.run {
                (try SubtitleFileReader.document(at: first), try SubtitleFileReader.document(at: second))
            }
            guard previewPair.map({ $0 == (first, second) }) == true else { return }
            loaded = documents
            error = ""
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func detectOffset() {
        guard let loaded else { return }
        detecting = true
        status = ""; error = ""
        Task {
            let found = try? await SubtitleBackgroundWork.run { loaded.secondary.estimatedOffset(to: loaded.primary) }
            detecting = false
            if let found {
                options.secondaryOffsetMs = found
                status = AppLocalization.format("merge.detect.found", found)
            } else {
                error = AppLocalization.string("merge.detect.none")
            }
        }
    }

    // MARK: Export

    private func fileName(for source: URL, role: SubtitleOutputFile.Role = .bilingual) -> String {
        OutputNaming.fileName(pattern: role == .bilingual ? pattern : "{name}.synced", source: source, format: options.format)
    }

    private func export() {
        status = ""; error = ""
        switch mode {
        case .pair: exportPair()
        case .season: exportSeason()
        }
    }

    private func exportPair() {
        guard let (first, second) = previewPair else { return }
        let options = options
        var destinations: [SubtitleOutputFile.Role: URL] = [:]
        if options.layout == .combined {
            let panel = NSSavePanel()
            panel.prompt = AppLocalization.string("movpkg.exportPrompt")
            panel.allowedContentTypes = [UTType(filenameExtension: options.format.fileExtension) ?? .plainText]
            panel.directoryURL = first.deletingLastPathComponent()
            panel.nameFieldStringValue = OutputNaming.fileName(pattern: "{name}.bilingual", source: first, format: options.format)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destinations[.bilingual] = url
        } else {
            guard let folder = SubtitleFilePanel.pickFolder(startingAt: first.deletingLastPathComponent()) else { return }
            for (role, source) in [(SubtitleOutputFile.Role.primary, first), (.secondary, second)] {
                destinations[role] = OutputNaming.destination(fileName: fileName(for: source, role: role), in: folder, existing: .rename,
                                                              protected: [first.standardizedFileURL, second.standardizedFileURL])
            }
        }
        let targets = destinations
        run {
            let written = try await SubtitleBackgroundWork.run {
                let files = try SubtitleDocument.merged(primary: try SubtitleFileReader.document(at: first),
                                                        secondary: try SubtitleFileReader.document(at: second), options: options)
                return try files.compactMap { file -> URL? in
                    guard let url = targets[file.role] else { return nil }
                    try file.contents.write(to: url, atomically: true, encoding: .utf8)
                    return url
                }
            }
            status = AppLocalization.format("merge.status.written", written.map(\.lastPathComponent).joined(separator: ", "))
            if let url = written.first { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func exportSeason() {
        let pairs = pairing.pairs, options = options, detect = autoDetect, existing = existing
        let folder = folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath)
        let pattern = pattern
        let protected = Set((primaryFiles + secondaryFiles).map(\.standardizedFileURL))
        run {
            var written: [URL] = [], skipped = 0, failures: [String] = []
            for (index, pair) in pairs.enumerated() {
                try Task.checkCancellation()
                status = AppLocalization.format("merge.status.progress", index + 1, pairs.count)
                do {
                    let (urls, kept) = try await SubtitleBackgroundWork.run {
                        let first = try SubtitleFileReader.document(at: pair.primary)
                        let second = try SubtitleFileReader.document(at: pair.secondary)
                        var lined = options
                        if detect { lined.secondaryOffsetMs = second.estimatedOffset(to: first) ?? options.secondaryOffsetMs }
                        var urls: [URL] = [], kept = 0
                        for file in try SubtitleDocument.merged(primary: first, secondary: second, options: lined) {
                            let source = file.role == .secondary ? pair.secondary : pair.primary
                            let name = OutputNaming.fileName(pattern: file.role == .bilingual ? pattern : "{name}.synced",
                                                             source: source, format: lined.format)
                            guard let url = OutputNaming.destination(fileName: name, in: folder ?? source.deletingLastPathComponent(),
                                                                     existing: existing, protected: protected) else {
                                kept += 1
                                continue
                            }
                            try file.contents.write(to: url, atomically: true, encoding: .utf8)
                            urls.append(url)
                        }
                        return (urls, kept)
                    }
                    written += urls
                    skipped += kept
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append("\(pair.key.label): \(error.localizedDescription)")
                }
            }
            status = AppLocalization.format("merge.status.season", written.count, skipped)
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
            if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        operation = Task {
            do {
                try await work()
            } catch is CancellationError {
                status = AppLocalization.string("download.status.cancelled")
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
            operation = nil
        }
    }
}
