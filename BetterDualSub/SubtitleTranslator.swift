import Foundation
import Combine
import Translation

/// A language the on-device translator offers, keyed by its maximal identifier ("zh-Hans-CN").
struct TranslationLanguage: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Creates Track 2 by translating Track 1 with the on-device macOS translator. It lives outside any view so a long
/// translation keeps going when the user leaves the page; only a language download needs a view (see `pending`).
@MainActor
final class SubtitleTranslator: ObservableObject {
    static let shared = SubtitleTranslator()
    private static let batchSize = 40

    enum Phase: Equatable {
        case idle
        /// Checking languages, or waiting for the user to accept a language download.
        case preparing
        case translating(done: Int, total: Int)
        case finished(lines: Int, language: String)
        case failed(String)
        case cancelled
    }

    struct Request {
        let plan: SubtitleTranslationPlan
        let source: Locale.Language
        let target: Locale.Language
        let loadID: UUID
        let token: UUID
        let preview: Bool
    }

    @Published private(set) var phase: Phase = .idle
    /// The subtitle load `phase` belongs to; after a new load it is stale.
    private(set) var loadID: UUID?
    /// The finished translation and its language, for export.
    private(set) var result: (document: SubtitleDocument, language: Locale.Language)?
    private(set) var previewOnly = false
    /// A request waiting for a language download, which only a view's translation session can offer.
    private var pending: Request?
    var pendingID: UUID? { pending?.token }
    private var task: Task<Void, Never>?
    private var session: TranslationSession?
    private var generation = UUID()

    var isBusy: Bool {
        switch phase {
        case .preparing, .translating: true
        default: false
        }
    }

    static func languages() async -> [TranslationLanguage] {
        let locale = AppLocalization.locale
        return await LanguageAvailability().supportedLanguages
            .map { TranslationLanguage(id: $0.maximalIdentifier, name: displayName($0, locale: locale)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Chinese is told apart by script (简体 / 繁體) rather than by region.
    static func displayName(_ language: Locale.Language, locale: Locale? = nil) -> String {
        let locale = locale ?? AppLocalization.locale
        let maximal = Locale.Language(identifier: language.maximalIdentifier)
        let identifier = maximal.languageCode == .chinese ? "zh-\(maximal.script?.identifier ?? "Hans")" : language.minimalIdentifier
        return locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// The app's interface language, or the other one of Chinese / English when the track is already in it.
    static func defaultTarget(source: Locale.Language?) -> String {
        let chinese = "zh-Hans-CN", english = "en-Latn-US"
        let preferred = AppLocalization.language == "zh-Hans" ? chinese : english
        guard let code = source?.languageCode, Locale.Language(identifier: preferred).languageCode == code else { return preferred }
        return preferred == chinese ? english : chinese
    }

    /// Starts translating. Returns a configuration when a language must be downloaded first: the view runs it with
    /// `.translationTask`, then calls `downloadFinished`.
    func start(plan: SubtitleTranslationPlan, source: Locale.Language, target: Locale.Language,
               manager: SubtitleManager, preview: Bool = false) async -> TranslationSession.Configuration? {
        guard !isBusy else { return nil }
        generation = UUID()
        let token = generation
        loadID = manager.loadID
        previewOnly = preview
        result = nil
        guard !plan.sources.isEmpty else { fail(AppLocalization.string("translate.error.empty")); return nil }
        phase = .preparing
        let request = Request(plan: plan, source: source, target: target, loadID: manager.loadID, token: token, preview: preview)
        let availability = await LanguageAvailability().status(from: source, to: target)
        guard generation == token, manager.loadID == request.loadID else { return nil }
        switch availability {
        case .installed:
            run(request, manager: manager)
        case .supported:
            pending = request
            return TranslationSession.Configuration(source: source, target: target)
        case .unsupported:
            fail(source.languageCode == target.languageCode
                 ? AppLocalization.format("translate.error.same", Self.displayName(target))
                 : AppLocalization.format("translate.error.unsupported", Self.displayName(source), Self.displayName(target)))
        @unknown default:
            fail(AppLocalization.format("translate.error.unsupported", Self.displayName(source), Self.displayName(target)))
        }
        return nil
    }

    /// Called by the view once the language download it offered is over (accepted, declined or failed).
    func downloadFinished(error: Error?, requestID: UUID?, manager: SubtitleManager) async {
        guard let request = pending, request.token == requestID else { return }
        pending = nil
        guard request.token == generation, request.loadID == manager.loadID else { return }
        if error is CancellationError { cancel(); return }
        if let error, !(error is CancellationError) {
            fail(error.localizedDescription)
            return
        }
        let availability = await LanguageAvailability().status(from: request.source, to: request.target)
        guard request.token == generation, request.loadID == manager.loadID else { return }
        guard availability == .installed else {
            fail(AppLocalization.string("translate.error.notInstalled"))
            return
        }
        run(request, manager: manager)
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        session?.cancel()
        task = nil
        session = nil
        pending = nil
        if isBusy { phase = .cancelled }
    }

    func clearResult() {
        cancel()
        result = nil
        phase = .idle
    }

    private func fail(_ message: String) {
        phase = .failed(message)
    }

    private func run(_ request: Request, manager: SubtitleManager) {
        guard request.token == generation, request.loadID == manager.loadID else { return }
        let session = TranslationSession(installedSource: request.source, target: request.target)
        self.session = session
        let sources = request.plan.sources
        phase = .translating(done: 0, total: sources.count)
        task = Task { [weak self] in
            do {
                var translations = [String](repeating: "", count: sources.count)
                var start = 0
                // Batches keep the progress moving and let a cancel or a new subtitle load stop the work early.
                while start < sources.count {
                    let end = min(sources.count, start + Self.batchSize)
                    let batch = (start..<end).map { TranslationSession.Request(sourceText: sources[$0], clientIdentifier: String($0)) }
                    let responses = try await session.translations(from: batch)
                    guard !Task.isCancelled, manager.loadID == request.loadID, self?.generation == request.token else { throw CancellationError() }
                    var received = Set<Int>()
                    for response in responses {
                        if let index = response.clientIdentifier.flatMap(Int.init), (start..<end).contains(index),
                           !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            translations[index] = response.targetText
                            received.insert(index)
                        }
                    }
                    guard received.count == end - start else { throw SubtitleError.message("error.translation.incomplete") }
                    start = end
                    self?.phase = .translating(done: start, total: sources.count)
                }
                let document = try request.plan.document(translations: translations)
                let language = Self.displayName(request.target)
                if !request.preview { manager.setSecondary(document, name: AppLocalization.format("translate.trackName", language)) }
                self?.result = (document, request.target)
                self?.phase = .finished(lines: document.items.count, language: language)
            } catch {
                guard self?.generation == request.token else { return }
                if error is CancellationError || Task.isCancelled {
                    self?.phase = .cancelled
                } else {
                    self?.fail(error.localizedDescription)
                }
            }
            guard self?.generation == request.token else { return }
            self?.session = nil
            self?.task = nil
        }
    }
}
