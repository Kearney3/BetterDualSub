import Foundation
import Combine
import Translation

/// A language the on-device translator offers, keyed by its maximal identifier ("zh-Hans-CN").
struct TranslationLanguage: Identifiable, Hashable {
    let id: String
    let name: String
}

/// What translates: the macOS on-device translator, or a language model behind an OpenAI-compatible API.
nonisolated enum SubtitleTranslationEngine: Equatable, Sendable {
    case system
    case llm(LLMConfiguration)
}

nonisolated struct SubtitleTranslationOptions: Sendable {
    var engine = SubtitleTranslationEngine.system
    /// Names and terms to translate the same way throughout; terms found before translating are added to it.
    var glossary: TranslationGlossary?
    /// Let the language model find the show's names and terms before translating.
    var extractTerms = false
    /// Break translated lines too long for one cue into parts (`SubtitleTranslationSplitter.subdivide`).
    var subdivide = true
    /// Chinese and Japanese subtitle punctuation (`SubtitleTranslationSplitter.subtitlePunctuation`); other target
    /// languages are left alone.
    var subtitlePunctuation = false
}

/// Creates Track 2 by translating Track 1, with the on-device macOS translator or a language model. It lives outside
/// any view so a long translation keeps going when the user leaves the page; only a language download needs a view
/// (see `pending`).
///
/// A sentence spread over several cues is translated whole and shared out over the same cues again. With a language
/// model the show's names and terms can be gathered into its glossary first, each batch is sent with the lines around
/// it and the glossary terms it uses, and lines that still ignore the glossary are asked for once more.
@MainActor
final class SubtitleTranslator: ObservableObject {
    static let shared = SubtitleTranslator()
    private static let batchSize = 40
    /// Sentences per term-extraction request.
    private static let termChunkSize = 300
    /// Untranslated sentences after a batch sent along for context.
    private static let followingContext = 3

    enum Phase: Equatable {
        case idle
        /// Checking languages, or waiting for the user to accept a language download.
        case preparing
        case extractingTerms(done: Int, total: Int)
        case termsExtracted(added: Int)
        case translating(done: Int, total: Int)
        /// Asking again for lines that did not use the glossary.
        case checking
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
        let options: SubtitleTranslationOptions
        /// Only gather glossary terms, without translating.
        let extractOnly: Bool
    }

    @Published private(set) var phase: Phase = .idle
    /// The subtitle load `phase` belongs to; after a new load it is stale.
    private(set) var loadID: UUID?
    /// The finished translation and its language, for export.
    private(set) var result: (document: SubtitleDocument, language: Locale.Language)?
    private(set) var previewOnly = false
    /// Sentences of the finished translation that still do not use a glossary term.
    private(set) var unresolvedTerms = 0
    /// The glossary as the last run left it, with the terms it found.
    @Published private(set) var glossary: TranslationGlossary?
    /// A request waiting for a language download, which only a view's translation session can offer.
    private var pending: Request?
    var pendingID: UUID? { pending?.token }
    /// A load whose Track 2 is to be translated as soon as the translation card has its languages ready.
    private var automaticLoadID: UUID?
    private var task: Task<Void, Never>?
    private var session: (any SubtitleTranslationSession)?
    private var generation = UUID()
    private let availability: (Locale.Language, Locale.Language) async -> LanguageAvailability.Status
    private let makeSession: (SubtitleTranslationEngine, Locale.Language, Locale.Language) -> any SubtitleTranslationSession
    private let saveGlossary: (TranslationGlossary) async -> Void

    init(availability: @escaping (Locale.Language, Locale.Language) async -> LanguageAvailability.Status = systemAvailability,
         makeSession: ((SubtitleTranslationEngine, Locale.Language, Locale.Language) -> any SubtitleTranslationSession)? = nil,
         saveGlossary: ((TranslationGlossary) async -> Void)? = nil) {
        self.availability = availability
        self.makeSession = makeSession ?? { Self.defaultSession(engine: $0, source: $1, target: $2) }
        self.saveGlossary = saveGlossary ?? { try? await GlossaryStore.shared.save($0) }
    }

    static func defaultSession(engine: SubtitleTranslationEngine, source: Locale.Language,
                               target: Locale.Language) -> any SubtitleTranslationSession {
        switch engine {
        case .system:
            SystemSubtitleTranslationSession(source: source, target: target)
        case .llm(let configuration):
            LLMSubtitleTranslationSession(client: LLMTranslationClient(configuration: configuration, apiKey: configuration.apiKey),
                                          source: source, target: target, prompt: LLMPromptLibrary.template(id: configuration.promptID))
        }
    }

    var isBusy: Bool {
        switch phase {
        case .preparing, .extractingTerms, .translating, .checking: true
        default: false
        }
    }

    static func languages() async -> [TranslationLanguage] {
        let locale = AppLocalization.locale
        return await supportedLanguages()
            .map { TranslationLanguage(id: $0.maximalIdentifier, name: displayName($0, locale: locale)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @concurrent private nonisolated static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    @concurrent private nonisolated static func systemAvailability(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
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
               manager: any SubtitleTranslationTarget, preview: Bool = false,
               options: SubtitleTranslationOptions = SubtitleTranslationOptions()) async -> TranslationSession.Configuration? {
        await begin(plan: plan, source: source, target: target, manager: manager, preview: preview, options: options, extractOnly: false)
    }

    /// Gathers the show's names and terms into `options.glossary` with the language model, without translating.
    func extractTerms(plan: SubtitleTranslationPlan, source: Locale.Language, target: Locale.Language,
                      manager: any SubtitleTranslationTarget, options: SubtitleTranslationOptions) async {
        guard case .llm = options.engine else { return }
        _ = await begin(plan: plan, source: source, target: target, manager: manager, preview: false, options: options, extractOnly: true)
    }

    private func begin(plan: SubtitleTranslationPlan, source: Locale.Language, target: Locale.Language,
                       manager: any SubtitleTranslationTarget, preview: Bool, options: SubtitleTranslationOptions,
                       extractOnly: Bool) async -> TranslationSession.Configuration? {
        guard !isBusy else { return nil }
        generation = UUID()
        let token = generation
        loadID = manager.loadID
        previewOnly = preview
        result = nil
        unresolvedTerms = 0
        glossary = options.glossary
        guard !plan.sources.isEmpty else { fail(AppLocalization.string("translate.error.empty")); return nil }
        phase = .preparing
        let request = Request(plan: plan, source: source, target: target, loadID: manager.loadID, token: token, preview: preview,
                              options: options, extractOnly: extractOnly)
        if case .llm(let configuration) = options.engine {
            // A language model needs no language download; it only needs to be set up.
            guard configuration.isComplete else { fail(AppLocalization.string("llm.error.notConfigured")); return nil }
            if source.languageCode == target.languageCode, source.script == target.script {
                fail(AppLocalization.format("translate.error.same", Self.displayName(target)))
                return nil
            }
            run(request, manager: manager)
            return nil
        }
        let availability = await availability(source, target)
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
    func downloadFinished(error: Error?, requestID: UUID?, manager: any SubtitleTranslationTarget) async {
        guard let request = pending, request.token == requestID else { return }
        pending = nil
        guard request.token == generation, request.loadID == manager.loadID else { return }
        if error is CancellationError { cancel(); return }
        if let error, !(error is CancellationError) {
            fail(error.localizedDescription)
            return
        }
        let availability = await availability(request.source, request.target)
        guard request.token == generation, request.loadID == manager.loadID else { return }
        guard availability == .installed else {
            fail(AppLocalization.string("translate.error.notInstalled"))
            return
        }
        run(request, manager: manager)
    }

    /// Asks for Track 2 of the subtitles just loaded to be translated without a click, as when only one track of a
    /// package was extracted on purpose.
    func requestAutomaticStart(loadID: UUID) {
        automaticLoadID = loadID
    }

    /// Whether `requestAutomaticStart` asked for `loadID`; answers yes once.
    func takeAutomaticStart(loadID: UUID) -> Bool {
        guard automaticLoadID == loadID else { return false }
        automaticLoadID = nil
        return true
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

    private func run(_ request: Request, manager: any SubtitleTranslationTarget) {
        guard request.token == generation, request.loadID == manager.loadID else { return }
        let session = makeSession(request.options.engine, request.source, request.target)
        self.session = session
        let units = request.plan.units
        let batchSize: Int, contextLines: Int, untranslated: Set<GlossaryEntry.Kind>
        if case .llm(let configuration) = request.options.engine {
            batchSize = min(max(configuration.batchSize, LLMConfiguration.batchSizes.lowerBound), LLMConfiguration.batchSizes.upperBound)
            contextLines = min(max(configuration.contextLines, 0), LLMConfiguration.contextSizes.upperBound)
            untranslated = configuration.untranslatedKinds
        } else {
            batchSize = Self.batchSize
            contextLines = 0
            untranslated = []
        }
        task = Task { [weak self] in
            defer { session.cancel() }
            @MainActor func ensureCurrent() throws {
                guard !Task.isCancelled, manager.loadID == request.loadID, self?.generation == request.token else { throw CancellationError() }
            }
            do {
                var glossary = request.options.glossary ?? TranslationGlossary(name: "", targetLanguage: request.target.maximalIdentifier)
                if session.understandsContext, request.options.extractTerms || request.extractOnly {
                    let chunks = stride(from: 0, to: units.count, by: Self.termChunkSize).map {
                        units[$0..<min(units.count, $0 + Self.termChunkSize)].map(\.text)
                    }
                    self?.phase = .extractingTerms(done: 0, total: chunks.count)
                    var added = 0
                    for (index, lines) in chunks.enumerated() {
                        let found = try await session.extractTerms(lines, known: glossary.matches(in: lines.joined(separator: "\n")))
                        try ensureCurrent()
                        added += glossary.merge(found)
                        self?.phase = .extractingTerms(done: index + 1, total: chunks.count)
                    }
                    self?.glossary = glossary
                    if added > 0, !glossary.name.isEmpty {
                        await self?.saveGlossary(glossary)
                        try ensureCurrent()
                    }
                    if request.extractOnly {
                        self?.phase = .termsExtracted(added: added)
                        self?.session = nil
                        self?.task = nil
                        return
                    }
                }
                // Found names of kinds left untranslated stay in the saved glossary for later runs but are not used.
                let applied = glossary.excludingAutomatic(untranslated)
                var translations = [[String]?](repeating: nil, count: units.count)
                self?.phase = .translating(done: 0, total: units.count)
                var start = 0
                // Batches keep the progress moving and let a cancel or a new subtitle load stop the work early.
                while start < units.count {
                    let end = min(units.count, start + batchSize)
                    var context = SubtitleTranslationContext()
                    if session.understandsContext {
                        context.preceding = (max(0, start - contextLines)..<start).compactMap { index in
                            translations[index].map { (source: units[index].text, translation: Self.joined($0)) }
                        }
                        context.following = units[end..<min(units.count, end + Self.followingContext)].map(\.text)
                        context.glossary = applied.matches(in: units[start..<end].map(\.text).joined(separator: "\n"))
                    }
                    let done = start
                    let batch = try await Self.translate(Array(start..<end), of: units, session: session, context: context,
                                                         glossary: applied, requireAll: true, ensureCurrent: ensureCurrent) { received in
                        self?.phase = .translating(done: done + received, total: units.count)
                    }
                    for (index, lines) in batch { translations[index] = lines }
                    start = end
                    self?.phase = .translating(done: start, total: units.count)
                }
                var violating = units.indices.filter { index in
                    translations[index].map { !applied.violations(source: units[index].text, translation: Self.joined($0)).isEmpty } ?? false
                }
                if session.understandsContext, !violating.isEmpty {
                    self?.phase = .checking
                    for first in stride(from: 0, to: violating.count, by: batchSize) {
                        let indices = Array(violating[first..<min(violating.count, first + batchSize)])
                        var context = SubtitleTranslationContext(strict: true)
                        context.glossary = applied.matches(in: indices.map { units[$0].text }.joined(separator: "\n"))
                        let retried: [Int: [String]]
                        do {
                            retried = try await Self.translate(indices, of: units, session: session, context: context, glossary: applied,
                                                               requireAll: false, ensureCurrent: ensureCurrent) { _ in }
                        } catch is SubtitleError {
                            // The first translation stands; a failed second opinion only leaves those lines unresolved.
                            continue
                        }
                        for (index, lines) in retried {
                            let before = translations[index].map { applied.violations(source: units[index].text, translation: Self.joined($0)).count } ?? .max
                            if applied.violations(source: units[index].text, translation: Self.joined(lines)).count < before { translations[index] = lines }
                        }
                    }
                    violating = violating.filter { index in
                        translations[index].map { !applied.violations(source: units[index].text, translation: Self.joined($0)).isEmpty } ?? false
                    }
                }
                try ensureCurrent()
                var document = try request.plan.document(translations: translations.map { $0 ?? [] })
                if request.options.subdivide { document = try SubtitleTranslationSplitter.subdivide(document) }
                if request.options.subtitlePunctuation, [.chinese, .japanese].contains(request.target.languageCode) {
                    let japanese = request.target.languageCode == .japanese
                    document = try SubtitleDocument(items: document.items.map {
                        SubtitleItem(startMs: $0.startMs, endMs: $0.endMs,
                                     text: SubtitleTranslationSplitter.subtitlePunctuation($0.text, japanese: japanese))
                    })
                }
                let language = Self.displayName(request.target)
                if !request.preview { manager.setSecondary(document, name: AppLocalization.format("translate.trackName", language)) }
                self?.unresolvedTerms = violating.count
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

    /// Translates `indices` of `units` in one request. Each result has one line per segment of its unit: kept from a
    /// translator that understands segments, otherwise shared out by `SubtitleTranslationSplitter`. Late, unknown,
    /// repeated or empty responses fail the request; so do missing ones when `requireAll` is set.
    private static func translate(_ indices: [Int], of units: [SubtitleTranslationUnit], session: any SubtitleTranslationSession,
                                  context: SubtitleTranslationContext, glossary: TranslationGlossary, requireAll: Bool,
                                  ensureCurrent: () throws -> Void, progress: (Int) -> Void) async throws -> [Int: [String]] {
        let wanted = Set(indices)
        let aware = session.understandsContext
        let inputs = indices.map { index in
            aware ? SubtitleTranslationInput(index: index, text: units[index].text, segments: units[index].segments)
                // Translators that cannot be told about a glossary get its translations written into the source.
                : SubtitleTranslationInput(index: index, text: glossary.substitute(in: units[index].text))
        }
        var results: [Int: [String]] = [:]
        try await session.translate(inputs, context: context) { response in
            try ensureCurrent()
            guard let index = response.identifier.flatMap(Int.init), wanted.contains(index),
                  !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  results[index] == nil else { throw SubtitleError.message("error.translation.incomplete") }
            let segments = units[index].segments
            if let lines = response.segments, lines.count == segments.count {
                results[index] = lines
            } else {
                results[index] = SubtitleTranslationSplitter.split(response.text, weights: segments.map(SubtitleLineMode.width))
            }
            progress(results.count)
        }
        try ensureCurrent()
        guard !requireAll || results.count == indices.count else { throw SubtitleError.message("error.translation.incomplete") }
        return results
    }

    private static func joined(_ lines: [String]) -> String {
        lines.filter { !$0.isEmpty }.reduce("") { $0.isEmpty ? $1 : SubtitleLineMode.join($0, $1) }
    }
}
