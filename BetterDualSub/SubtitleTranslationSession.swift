import Foundation
import Translation

@MainActor
protocol SubtitleTranslationTarget: AnyObject, Sendable {
    var loadID: UUID { get }
    func setSecondary(_ document: SubtitleDocument, name: String)
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

    init(source: Locale.Language, target: Locale.Language) {
        session = TranslationSession(installedSource: source, target: target)
    }

    func translate(_ inputs: [SubtitleTranslationInput], context: SubtitleTranslationContext,
                   receive: (SubtitleTranslationOutput) throws -> Void) async throws {
        try Task.checkCancellation()
        let requests = inputs.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.index)) }
        for try await response in session.translate(batch: requests) {
            try Task.checkCancellation()
            try receive(SubtitleTranslationOutput(identifier: response.clientIdentifier, text: response.targetText))
        }
        try Task.checkCancellation()
    }

    func cancel() { session.cancel() }
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
