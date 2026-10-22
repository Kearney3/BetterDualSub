import Foundation
import Translation

@MainActor
protocol SubtitleTranslationTarget: AnyObject, Sendable {
    var loadID: UUID { get }
    func setSecondary(_ document: SubtitleDocument, name: String)
}

nonisolated struct SubtitleTranslationInput: Sendable {
    let index: Int
    let text: String
}

nonisolated struct SubtitleTranslationOutput: Sendable {
    let identifier: String?
    let text: String
}

/// Both the stream and cancellation belong to MainActor; the native session never leaves it.
@MainActor
protocol SubtitleTranslationSession: AnyObject {
    func translate(_ inputs: [SubtitleTranslationInput], receive: (SubtitleTranslationOutput) throws -> Void) async throws
    func cancel()
}

@MainActor
final class SystemSubtitleTranslationSession: SubtitleTranslationSession {
    private let session: TranslationSession

    init(source: Locale.Language, target: Locale.Language) {
        session = TranslationSession(installedSource: source, target: target)
    }

    func translate(_ inputs: [SubtitleTranslationInput], receive: (SubtitleTranslationOutput) throws -> Void) async throws {
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
