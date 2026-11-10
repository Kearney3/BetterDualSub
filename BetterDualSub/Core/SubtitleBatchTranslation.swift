import Foundation
import Combine
import Translation

/// Translates a list of subtitle files one after another and writes the results: the translation, a bilingual file
/// of each source with its translation, or both. With a language model the glossary grows as it goes, so names found
/// in one episode are translated the same way in the next. It lives outside any view, so a run keeps going when the
/// page is left; only a language download needs the page (see `download`).
@MainActor
final class SubtitleBatchTranslator: ObservableObject {
    static let shared = SubtitleBatchTranslator()

    enum Status: Equatable {
        case waiting
        case reading
        case extractingTerms(done: Int, total: Int)
        case translating(done: Int, total: Int)
        case checking
        /// Written to these files.
        case done([URL])
        /// Every file it would write is already there and is kept.
        case skipped
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .done, .skipped: true
            default: false
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let url: URL
        var status = Status.waiting
        var id: URL { url }
    }

    /// What to write for each source and where.
    struct Outputs: Equatable, Sendable {
        var translation = true
        /// Merge options for a bilingual file of the source and its translation; nil writes none.
        var bilingual: BilingualMergeOptions?
        /// nil writes next to each source.
        var folder: URL?
        var translationPattern = "{name}.{lang}"
        var bilingualPattern = "{name}.bilingual"
        var existing = OutputNaming.ExistingFile.skip
    }

    /// The translation side of a file: nothing is shown, the finished document is taken from `translator.result`.
    final class FileTarget: SubtitleTranslationTarget {
        let loadID = UUID()
        var translationPositionMs: Int { 0 }
        func setSecondary(_ document: SubtitleDocument, name: String) {}
        func updateSecondary(_ document: SubtitleDocument) {}
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    /// The glossary as the run has left it, with the terms found so far.
    @Published private(set) var glossary: TranslationGlossary?
    /// A language download the page should offer with `.translationTask`, for the file now running.
    @Published private(set) var download: TranslationSession.Configuration?
    private(set) var currentTarget = FileTarget()
    var pendingID: UUID? { translator.pendingID }
    let translator: SubtitleTranslator
    private var current: Int?
    private var task: Task<Void, Never>?
    private var phaseObserver: AnyCancellable?

    init(translator: SubtitleTranslator = SubtitleTranslator()) {
        self.translator = translator
        phaseObserver = translator.$phase.sink { [weak self] phase in self?.follow(phase) }
    }

    var failedCount: Int { items.filter { if case .failed = $0.status { true } else { false } }.count }
    var finishedCount: Int { items.filter(\.status.isFinished).count }

    /// Replaces the list of files; ignored while running.
    func setFiles(_ urls: [URL]) {
        guard !isRunning else { return }
        let old = Dictionary(items.map { ($0.url, $0.status) }, uniquingKeysWith: { first, _ in first })
        // A file still listed keeps its result, so the list can grow between runs.
        items = urls.map { Item(url: $0, status: old[$0] ?? .waiting) }
    }

    /// Translates every file not yet done.
    func start(source: Locale.Language, target: Locale.Language, options: SubtitleTranslationOptions, outputs: Outputs) {
        run(items.indices.filter { !items[$0].status.isFinished }, source: source, target: target, options: options, outputs: outputs)
    }

    /// Translates the files that failed or were cancelled again.
    func retryFailed(source: Locale.Language, target: Locale.Language, options: SubtitleTranslationOptions, outputs: Outputs) {
        run(items.indices.filter {
            switch items[$0].status {
            case .failed, .cancelled: true
            default: false
            }
        }, source: source, target: target, options: options, outputs: outputs)
    }

    func cancel() {
        task?.cancel()
        translator.cancel()
    }

    /// Forgets the results, so the next run translates every file again.
    func reset() {
        guard !isRunning else { return }
        items = items.map { Item(url: $0.url) }
    }

    private func follow(_ phase: SubtitleTranslator.Phase) {
        if phase != .preparing { download = nil }
        guard let current, items.indices.contains(current) else { return }
        switch phase {
        case .extractingTerms(let done, let total): items[current].status = .extractingTerms(done: done, total: total)
        case .translating(let done, let total): items[current].status = .translating(done: done, total: total)
        case .checking: items[current].status = .checking
        default: break
        }
    }

    private func run(_ indices: [Int], source: Locale.Language, target: Locale.Language,
                     options: SubtitleTranslationOptions, outputs: Outputs) {
        guard !isRunning, !indices.isEmpty else { return }
        isRunning = true
        glossary = options.glossary
        for index in indices { items[index].status = .waiting }
        let language = SubtitleTranslator.fileCode(target)
        task = Task { [weak self] in
            var glossary = options.glossary
            for index in indices {
                guard let self, !Task.isCancelled else { break }
                let url = self.items[index].url
                let plans = Self.destinations(for: url, language: language, sourceLanguage: source, outputs: outputs,
                                              sources: Set(self.items.map(\.url)))
                if plans.allSatisfy({ $0.destination == nil }) {
                    self.items[index].status = .skipped
                    continue
                }
                self.current = index
                self.items[index].status = .reading
                do {
                    let document = try await SubtitleBackgroundWork.run { try SubtitleFileReader.document(at: url) }
                    let plan = SubtitleTranslationPlan(document: document)
                    var fileOptions = options
                    fileOptions.glossary = glossary
                    self.currentTarget = FileTarget()
                    let configuration = await self.translator.start(plan: plan, source: source, target: target,
                                                                    manager: self.currentTarget, options: fileOptions)
                    if let configuration { self.download = configuration }
                    await self.translator.waitUntilIdle()
                    if let found = self.translator.glossary { glossary = found; self.glossary = found }
                    switch self.translator.phase {
                    case .finished:
                        guard let translated = self.translator.result?.document else { throw SubtitleError.message("error.translation.incomplete") }
                        let written = try await SubtitleBackgroundWork.run {
                            try Self.write(plans, source: document, translation: translated)
                        }
                        self.items[index].status = .done(written)
                    case .failed(let message):
                        self.items[index].status = .failed(message)
                    default:
                        self.items[index].status = .cancelled
                    }
                } catch {
                    self.items[index].status = Task.isCancelled || error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                }
                if Task.isCancelled { break }
            }
            guard let self else { return }
            for index in indices where self.items[index].status == .waiting { self.items[index].status = .cancelled }
            if Task.isCancelled, let current = self.current, !self.items[current].status.isFinished {
                self.items[current].status = .cancelled
            }
            self.current = nil
            self.download = nil
            self.isRunning = false
            self.task = nil
        }
    }

    /// One file a source should produce, and where it goes (nil when it already exists and is kept).
    struct Planned: Sendable {
        let role: SubtitleOutputFile.Role
        let destination: URL?
        let merge: BilingualMergeOptions?
    }

    nonisolated static func destinations(for source: URL, language: String, sourceLanguage: Locale.Language? = nil,
                                         outputs: Outputs, sources: Set<URL>) -> [Planned] {
        let folder = outputs.folder ?? source.deletingLastPathComponent()
        let protected = Set(sources.map(\.standardizedFileURL))
        var planned: [Planned] = []
        if outputs.translation {
            let name = OutputNaming.fileName(pattern: outputs.translationPattern, source: source, language: language,
                                             sourceLanguage: sourceLanguage, format: .srt)
            planned.append(Planned(role: .translation, destination: OutputNaming.destination(fileName: name, in: folder,
                                                                                             existing: outputs.existing, protected: protected),
                                   merge: nil))
        }
        if let merge = outputs.bilingual {
            let name = OutputNaming.fileName(pattern: outputs.bilingualPattern, source: source, language: language,
                                             sourceLanguage: sourceLanguage, format: merge.format)
            planned.append(Planned(role: .bilingual, destination: OutputNaming.destination(fileName: name, in: folder,
                                                                                           existing: outputs.existing, protected: protected),
                                   merge: merge))
        }
        return planned
    }

    nonisolated private static func write(_ planned: [Planned], source: SubtitleDocument, translation: SubtitleDocument) throws -> [URL] {
        try planned.compactMap { file in
            guard let url = file.destination else { return nil }
            let contents: String
            if var merge = file.merge {
                // The translation is timed within the source's cues: one bilingual file, whatever layout was chosen.
                merge.layout = .combined
                merge.secondaryOffsetMs = 0
                contents = try SubtitleDocument.merged(primary: source, secondary: translation, options: merge).first?.contents ?? ""
            } else {
                contents = translation.srt
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}
