import Foundation
import Translation
import NaturalLanguage

@MainActor
protocol SubtitleTranslationTarget: AnyObject, Sendable {
    var loadID: UUID { get }
    /// Where Track 1 is being watched, in its own time (after its delay), so translation starts there.
    var translationPositionMs: Int { get }
    func setSecondary(_ document: SubtitleDocument, name: String)
    /// Replaces the Track 2 that `setSecondary` set as more of it is translated; undo still returns to the one before.
    func updateSecondary(_ document: SubtitleDocument)
}

nonisolated struct SubtitleTranslationInput: Sendable {
    let index: Int
    /// The whole sentence.
    let text: String
    /// The sentence as it is split over its cues, for translators that can keep that split.
    var segments: [String]

    init(index: Int, text: String, segments: [String]? = nil) {
        self.index = index
        self.text = text
        self.segments = segments ?? [text]
    }
}

nonisolated struct SubtitleTranslationOutput: Sendable {
    let identifier: String?
    let text: String
    /// One line per segment of the input, when the translator kept the split.
    var segments: [String]? = nil
}

/// What a translator that understands context is told besides the lines of a batch.
nonisolated struct SubtitleTranslationContext: Sendable {
    /// The sentences just before the batch, with their translations.
    var preceding: [(source: String, translation: String)] = []
    /// The sentences just after the batch, not yet translated.
    var following: [String] = []
    /// Glossary entries that occur in the batch.
    var glossary: [GlossaryEntry] = []
    /// A second attempt at lines that ignored the glossary.
    var strict = false
}

/// Both the stream and cancellation belong to MainActor; the native session never leaves it.
@MainActor
protocol SubtitleTranslationSession: AnyObject {
    /// Whether `context` and the inputs' segments are used; otherwise each sentence is translated alone.
    var understandsContext: Bool { get }
    func translate(_ inputs: [SubtitleTranslationInput], context: SubtitleTranslationContext,
                   receive: (SubtitleTranslationOutput) throws -> Void) async throws
    /// Names and terms in `lines` with the translation to use for them; `known` are already settled.
    func extractTerms(_ lines: [String], known: [GlossaryEntry]) async throws -> [GlossaryEntry]
    func cancel()
}

extension SubtitleTranslationSession {
    var understandsContext: Bool { false }
    func extractTerms(_ lines: [String], known: [GlossaryEntry]) async throws -> [GlossaryEntry] { [] }
}

@MainActor
final class SystemSubtitleTranslationSession: SubtitleTranslationSession {
    private let session: TranslationSession
    private let script: StringTransform?
    private let source: Locale.Language

    init(source: Locale.Language, target: Locale.Language) {
        self.source = source
        session = TranslationSession(installedSource: source, target: target)
        script = Self.scriptTransform(to: target)
    }

    /// The system model now and then answers a Simplified Chinese request with Traditional characters, or the other
    /// way round; this turns them into the script asked for.
    nonisolated static func scriptTransform(to target: Locale.Language) -> StringTransform? {
        guard target.languageCode == .chinese else { return nil }
        return switch Locale.Language(identifier: target.maximalIdentifier).script {
        case .hanSimplified: StringTransform("Hant-Hans")
        case .hanTraditional: StringTransform("Hans-Hant")
        default: nil
        }
    }

    func translate(_ inputs: [SubtitleTranslationInput], context: SubtitleTranslationContext,
                   receive: (SubtitleTranslationOutput) throws -> Void) async throws {
        try Task.checkCancellation()
        let requests = inputs.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.index)) }
        for try await response in session.translate(batch: requests) {
            try Task.checkCancellation()
            let text = script.flatMap { response.targetText.applyingTransform($0, reverse: false) } ?? response.targetText
            try receive(SubtitleTranslationOutput(identifier: response.clientIdentifier, text: text))
        }
        try Task.checkCancellation()
    }

    /// Finds names with the on-device tagger and translates each with the system translator; the user corrects them.
    func extractTerms(_ lines: [String], known: [GlossaryEntry]) async throws -> [GlossaryEntry] {
        let knownSources = Set(known.map { $0.source.lowercased() })
        let names = GlossaryNameFinder.names(in: lines, language: source).filter { !knownSources.contains($0.text.lowercased()) }
        guard !names.isEmpty else { return [] }
        try Task.checkCancellation()
        let requests = names.enumerated().map { TranslationSession.Request(sourceText: $1.text, clientIdentifier: String($0)) }
        var entries: [GlossaryEntry] = []
        for try await response in session.translate(batch: requests) {
            try Task.checkCancellation()
            guard let index = response.clientIdentifier.flatMap(Int.init), names.indices.contains(index) else { continue }
            let text = script.flatMap { response.targetText.applyingTransform($0, reverse: false) } ?? response.targetText
            entries.append(GlossaryEntry(source: names[index].text, target: text, kind: names[index].kind))
        }
        return entries
    }

    func cancel() { session.cancel() }
}

/// Finds person, place and organization names in subtitle lines without a language model.
nonisolated enum GlossaryNameFinder {
    static func names(in lines: [String], language: Locale.Language) -> [(text: String, kind: GlossaryEntry.Kind)] {
        var counts: [String: (kind: GlossaryEntry.Kind, count: Int)] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType])
        for line in lines {
            tagger.string = line
            if let code = language.languageCode?.identifier { tagger.setLanguage(NLLanguage(code), range: line.startIndex..<line.endIndex) }
            tagger.enumerateTags(in: line.startIndex..<line.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                let kind: GlossaryEntry.Kind
                switch tag {
                case .personalName: kind = .person
                case .placeName: kind = .place
                case .organizationName: kind = .organization
                default: return true
                }
                let text = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > 1 { counts[text, default: (kind, 0)].count += 1 }
                return true
            }
        }
        return counts.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.map { ($0.key, $0.value.kind) }
    }
}

/// Immutable request context for SwiftUI's framework-owned language download session.
/// A concurrent method reference keeps the session local to its execution domain.
nonisolated final class SubtitleTranslationDownload: Sendable {
    private let requestID: UUID?
    private let translator: SubtitleTranslator
    private let target: any SubtitleTranslationTarget

    init(requestID: UUID?, translator: SubtitleTranslator, target: any SubtitleTranslationTarget) {
        self.requestID = requestID
        self.translator = translator
        self.target = target
    }

    @concurrent func prepare(_ session: TranslationSession) async {
        guard !Task.isCancelled, let requestID, await translator.pendingID == requestID else { return }
        do {
            try await session.prepareTranslation()
            await translator.downloadFinished(error: nil, requestID: requestID, manager: target)
        } catch {
            await translator.downloadFinished(error: error, requestID: requestID, manager: target)
        }
    }
}
