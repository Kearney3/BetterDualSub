import Foundation
import AVFoundation
import CoreMedia
import Speech

/// One recognized piece of speech and when it was said, in seconds from the start of the audio.
nonisolated struct TimedSpeech: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

/// Turns recognized speech into subtitle cues: a cue ends at the end of a sentence, at a comma once it is long, at a
/// pause, or when it would otherwise be too long to read.
nonisolated enum TranscriptCueBuilder {
    static let maximumCharacters = 84
    static let breakAtCommaFrom = 40
    static let maximumSeconds = 7.0
    static let pauseSeconds = 1.0
    static let minimumSeconds = 0.8

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
    private static let commas: Set<Character> = [",", "，", "、", ";", "；"]

    /// Cues for `pieces` in order. Pieces are joined as they are (recognizers keep their own spaces); a space is
    /// added only between two pieces that both lack one and are not written without spaces.
    static func cues(from pieces: [TimedSpeech]) -> [SubtitleItem] {
        var items: [SubtitleItem] = []
        var text = "", start = 0.0, end = 0.0
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard !trimmed.isEmpty else { return }
            let startMs = max(0, Int((start * 1000).rounded()))
            // Short cues stay up long enough to read, but never into the next one.
            let endMs = max(Int((end * 1000).rounded()), startMs + Int(minimumSeconds * 1000))
            items.append(SubtitleItem(startMs: startMs, endMs: endMs, text: trimmed))
        }
        for piece in pieces where !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !text.isEmpty, piece.start - end > pauseSeconds || piece.end - start > maximumSeconds { flush() }
            if text.isEmpty { start = piece.start }
            if let last = text.last, let first = piece.text.first, !last.isWhitespace, !first.isWhitespace,
               !isUnspaced(last), !isUnspaced(first) {
                text += " "
            }
            text += piece.text
            end = piece.end
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = trimmed.last else { continue }
            if sentenceEnds.contains(last) || trimmed.count >= maximumCharacters
                || (commas.contains(last) && trimmed.count >= breakAtCommaFrom) { flush() }
        }
        flush()
        // A cue must not overlap the next one, which the minimum duration could cause.
        return items.enumerated().map { index, item in
            guard index + 1 < items.count, item.endMs > items[index + 1].startMs else { return item }
            return SubtitleItem(startMs: item.startMs, endMs: max(item.startMs + 1, items[index + 1].startMs), text: item.text)
        }
    }

    /// Scripts written without spaces between words.
    private static func isUnspaced(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value) ||
            (0xF900...0xFAFF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value) ||
            (0x3000...0x303F).contains(scalar.value) || (0x0E00...0x0E7F).contains(scalar.value)
        }
    }
}

/// Recognizes the speech of a video or audio file on this Mac with the system speech analyzer, and makes subtitles of it.
nonisolated enum SpeechTranscription {
    enum Phase: Sendable, Equatable {
        /// The language's speech model is being downloaded; 0...1.
        case downloading(Double)
        /// The audio is being read out of the file, which takes a while for a large Matroska file.
        case reading
        /// Audio has been recognized up to this fraction of its length.
        case transcribing(Double)
    }

    struct Language: Identifiable, Sendable, Equatable {
        let locale: Locale
        /// The speech model is on this Mac; otherwise it is downloaded first.
        let installed: Bool
        var id: String { locale.identifier }
        var name: String { Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier }
    }

    /// Languages the analyzer knows, those already installed first.
    static func languages() async -> [Language] {
        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        return await SpeechTranscriber.supportedLocales.map { Language(locale: $0, installed: installed.contains($0.identifier)) }
            .sorted { ($0.installed ? 0 : 1, $0.name) < ($1.installed ? 0 : 1, $1.name) }
    }

    /// The language to offer first for audio in `tags` (language tags of the file's audio), else for the user's own
    /// preferred languages: an installed one, otherwise one that can be downloaded.
    static func preferred(among languages: [Language], audioTags: [String], preferred: [String] = Locale.preferredLanguages) -> Language? {
        for tag in audioTags + preferred {
            let wanted = Locale.Language(identifier: tag)
            let matches = languages.filter {
                $0.locale.language.languageCode == wanted.languageCode
                    && (wanted.region == nil || $0.locale.language.region == wanted.region)
            }
            if let best = matches.first(where: \.installed) ?? matches.first { return best }
        }
        return nil
    }

    /// The audio file for `url`, or nil when the system cannot read audio from it itself (Matroska files, for one).
    static func audioFile(at url: URL) -> AVAudioFile? { try? AVAudioFile(forReading: url) }

    private static func isMatroska(_ url: URL) -> Bool { VideoSubtitleExtractor.matroskaExtensions.contains(url.pathExtension.lowercased()) }

    /// The audio of `url` can be read: by the system, or, for a Matroska file, out of its first AAC track.
    static func canTranscribe(_ url: URL) -> Bool {
        audioFile(at: url) != nil || (isMatroska(url) && MatroskaAudio.firstSupportedTrack(in: url) != nil)
    }

    /// The audio of `url` as a file the system reads, and the temporary file made for it, if any, to delete afterwards.
    private static func prepareAudio(for url: URL, progress: @Sendable (Phase) -> Void) throws -> (file: AVAudioFile, temporary: URL?) {
        if let file = audioFile(at: url) { return (file, nil) }
        guard isMatroska(url), (try? MatroskaFile(url: url)) != nil else { throw SubtitleError.message("error.transcribe.unreadable") }
        guard let track = MatroskaAudio.firstSupportedTrack(in: url) else { throw SubtitleError.message("error.transcribe.unsupportedAudio") }
        progress(.reading)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDualSub-audio-\(UUID().uuidString).caf")
        do {
            try MatroskaAudio.writeCAF(of: track, from: url, to: temporary)
            guard let file = audioFile(at: temporary) else { throw SubtitleError.message("error.transcribe.audioExtraction") }
            return (file, temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Language tags of the file's audio tracks, such as "en-US".
    static func audioLanguageTags(of url: URL) async -> [String] {
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)) ?? []
        var tags: [String] = []
        for track in tracks {
            let extended = try? await track.load(.extendedLanguageTag)
            let code = try? await track.load(.languageCode)
            if let tag = extended ?? code { tags.append(tag) }
        }
        return tags
    }

    /// The subtitles of the speech in `url`. Takes about as long as a fraction of the audio; downloads the language's
    /// speech model first when it is not installed.
    @concurrent static func document(from url: URL, locale: Locale, progress: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> SubtitleDocument {
        let (file, temporary) = try prepareAudio(for: url, progress: progress)
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SubtitleError.message("error.transcribe.unsupportedLanguage")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let watcher = Task {
                while !Task.isCancelled {
                    progress(.downloading(request.progress.fractionCompleted))
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        }
        progress(.transcribing(0))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [TimedSpeech] in
            var pieces: [TimedSpeech] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    pieces.append(TimedSpeech(text: String(result.text[run.range].characters), start: range.start.seconds, end: range.end.seconds))
                }
                if seconds > 0, let last = pieces.last { progress(.transcribing(min(1, last.end / seconds))) }
            }
            return pieces
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let pieces = try await collector.value
            progress(.transcribing(1))
            let document = try SubtitleDocument(items: TranscriptCueBuilder.cues(from: pieces), allowEmpty: true)
            guard !document.items.isEmpty else { throw SubtitleError.message("error.transcribe.noSpeech") }
            return document
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}
