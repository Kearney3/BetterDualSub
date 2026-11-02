import SwiftUI
import AppKit
import Combine

/// The translation settings the Now Playing card and the batch page share: the engine, target language, and toggles
/// are app preferences, so a change in one place applies to both; the source language and glossary belong to whatever
/// is being translated.
@MainActor
final class TranslationOptionsModel: ObservableObject {
    static let targetKey = "translationTarget"
    static let engineKey = "translationEngine"
    static let extractTermsKey = "translationExtractTerms"
    static let subdivideKey = "translationSubdivide"
    static let subtitlePunctuationKey = "translationSubtitlePunctuation"

    @Published private(set) var languages: [TranslationLanguage] = []
    @Published var sourceID = ""
    @Published var glossaryName = ""
    /// The saved glossary named `glossaryName` for the target language, once loaded.
    @Published private(set) var glossary: TranslationGlossary?
    /// Glossaries saved for the target language.
    @Published private(set) var glossaryNames: [String] = []
    private var preferences: AnyCancellable?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The preferences live in UserDefaults; anything that reads them here redraws when they change.
        preferences = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var target: String {
        get { defaults.string(forKey: Self.targetKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.targetKey) }
    }

    var llm: LLMConfiguration {
        defaults.data(forKey: LLMConfiguration.storageKey).flatMap { try? JSONDecoder().decode(LLMConfiguration.self, from: $0) }
            ?? LLMConfiguration()
    }

    var usesLLM: Bool { defaults.string(forKey: Self.engineKey) == "llm" }

    var engine: SubtitleTranslationEngine { usesLLM ? .llm(llm) : .system }

    /// Source and target chosen, and the language model set up if one is used.
    var isReady: Bool { !sourceID.isEmpty && !target.isEmpty && (!usesLLM || llm.isComplete) }

    var sourceLanguage: Locale.Language? { sourceID.isEmpty ? nil : Locale.Language(identifier: sourceID) }
    var targetLanguage: Locale.Language? { target.isEmpty ? nil : Locale.Language(identifier: target) }

    func loadLanguages() async {
        if languages.isEmpty { languages = await SubtitleTranslator.languages() }
    }

    /// Chooses the source language for subtitles detected as `detected`, and a target other than it.
    func adopt(detected: Locale.Language?) async {
        await loadLanguages()
        sourceID = detected.flatMap { detected in
            languages.first { Locale.Language(identifier: $0.id).languageCode == detected.languageCode
                && Locale.Language(identifier: $0.id).script == Locale.Language(identifier: detected.maximalIdentifier).script }?.id
            ?? languages.first { Locale.Language(identifier: $0.id).languageCode == detected.languageCode }?.id
        } ?? ""
        if !languages.contains(where: { $0.id == target }) || detected?.languageCode == Locale.Language(identifier: target).languageCode {
            target = SubtitleTranslator.defaultTarget(source: detected)
        }
    }

    func loadGlossary() async {
        guard !glossaryName.isEmpty, !target.isEmpty else { glossary = nil; return }
        let name = glossaryName, language = target
        let loaded = try? await GlossaryStore.shared.load(name: name, targetLanguage: language)
        let names = await GlossaryStore.shared.names(targetLanguage: language)
        guard name == glossaryName, language == target else { return }
        glossary = loaded ?? TranslationGlossary(name: name, targetLanguage: language)
        glossaryNames = names
    }

    /// A glossary a run just updated (with the terms it found), when it is the one chosen here.
    func adopt(glossary updated: TranslationGlossary?) {
        if let updated, updated.name == glossaryName, updated.targetLanguage == target { glossary = updated }
    }

    /// Saves `glossary` and makes it the chosen one, as after editing it or saving it under another name.
    func save(_ glossary: TranslationGlossary) async throws {
        try await GlossaryStore.shared.save(glossary)
        glossaryName = glossary.name
        self.glossary = glossary
        await loadGlossary()
    }

    /// The run's options, once the chosen saved glossary is loaded: terms found during the run are merged into it and
    /// saved, so starting with an empty stand-in would replace the saved one.
    func options(preview: Bool) async -> SubtitleTranslationOptions {
        if glossary?.name != glossaryName || glossary?.targetLanguage != target { await loadGlossary() }
        return SubtitleTranslationOptions(engine: engine, glossary: glossary ?? TranslationGlossary(name: glossaryName, targetLanguage: target),
                                          extractTerms: usesLLM && (defaults.object(forKey: Self.extractTermsKey) as? Bool ?? true) && !preview,
                                          subdivide: defaults.object(forKey: Self.subdivideKey) as? Bool ?? true,
                                          subtitlePunctuation: defaults.bool(forKey: Self.subtitlePunctuationKey))
    }
}

/// Engine, languages, glossary and line options for a translation.
struct TranslationOptionsSection: View {
    @ObservedObject var model: TranslationOptionsModel
    var disabled = false
    /// Gathers the glossary terms now, for an engine that can; nil hides the button.
    var extract: (() -> Void)?
    var canExtract = false
    /// Offers saving the glossary under another name, for a later season.
    var allowsSaveAs = false
    /// Describes translating files rather than making Track 2.
    var forFiles = false
    @AppStorage(TranslationOptionsModel.targetKey) private var target = ""
    @AppStorage(TranslationOptionsModel.engineKey) private var engineID = "system"
    @AppStorage(TranslationOptionsModel.extractTermsKey) private var extractTerms = true
    @AppStorage(TranslationOptionsModel.subdivideKey) private var subdivide = true
    @AppStorage(TranslationOptionsModel.subtitlePunctuationKey) private var subtitlePunctuation = false
    @AppStorage(LLMConfiguration.storageKey) private var llmData = Data()
    @State private var editingGlossary = false
    @State private var savingAs = false
    @State private var newName = ""

    private var llm: LLMConfiguration {
        (try? JSONDecoder().decode(LLMConfiguration.self, from: llmData)) ?? LLMConfiguration()
    }

    private var usesLLM: Bool { engineID == "llm" }

    private var hintKey: LocalizedStringKey {
        switch (usesLLM, llm.isOnThisMac, forFiles) {
        case (false, _, false): "translate.help"
        case (true, true, false): "translate.help.llmLocal"
        case (true, false, false): "translate.help.llmRemote"
        case (false, _, true): "batch.help"
        case (true, true, true): "batch.help.llmLocal"
        case (true, false, true): "batch.help.llmRemote"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsHint(key: hintKey)
            HStack(spacing: 10) {
                Picker("translate.engine", selection: $engineID) {
                    Text("translate.engine.system").tag("system")
                    Text(verbatim: AppLocalization.format("translate.engine.llm", llm.model.isEmpty ? llm.preset.name : "\(llm.preset.name) · \(llm.model)"))
                        .tag("llm")
                }
                .fixedSize()
                .disabled(disabled)
                Spacer()
                if usesLLM {
                    Button(llm.isComplete ? "translate.engine.settings" : "translate.engine.configure") { showControlCenterPage("translation") }
                }
            }
            if usesLLM, llm.isComplete, !llm.isOnThisMac {
                StatusLine(text: AppLocalization.format("translate.privacy.remote", llm.keychainAccount))
            }
            HStack(spacing: 10) {
                Picker("translate.source.choose", selection: $model.sourceID) {
                    Text("translate.source.unknown").tag("")
                    ForEach(model.languages) { Text(verbatim: $0.name).tag($0.id) }
                }
                .disabled(disabled || model.languages.isEmpty)
                Spacer()
                Picker("translate.target", selection: $target) {
                    ForEach(model.languages) { Text(verbatim: $0.name).tag($0.id) }
                }
                .fixedSize()
                .disabled(disabled || model.languages.isEmpty)
            }
            glossaryRow
            Toggle("translate.subdivide", isOn: $subdivide).disabled(disabled)
            if [.chinese, .japanese].contains(Locale.Language(identifier: target).languageCode) {
                Toggle("translate.punctuation", isOn: $subtitlePunctuation).disabled(disabled)
            }
        }
        .task { await model.loadLanguages() }
        .task(id: "\(model.glossaryName)\u{0}\(target)") { await model.loadGlossary() }
        .sheet(isPresented: $editingGlossary) {
            GlossaryEditorView(glossary: model.glossary ?? TranslationGlossary(name: model.glossaryName, targetLanguage: target)) { edited in
                Task {
                    do { try await model.save(edited) } catch { NSAlert(error: error).runModal() }
                }
            }
        }
        .alert("translate.glossary.saveAs.title", isPresented: $savingAs) {
            TextField("translate.glossary.saveAs.name", text: $newName)
            Button("glossary.save", action: saveAs).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("translate.glossary.saveAs.message")
        }
    }

    /// The show's glossary for the target language: its name, size, and the ways to fill it.
    private var glossaryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A show's name can be long, so the picker takes the full width and truncates, with its controls below.
            Picker("translate.glossary", selection: $model.glossaryName) {
                ForEach(Array(Set(model.glossaryNames + [model.glossaryName])).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                        id: \.self) {
                    Text(verbatim: $0).tag($0)
                }
            }
            .disabled(disabled)
            .help(Text("translate.glossary.help"))
            HStack(spacing: 10) {
                Text(AppLocalization.format("glossary.count", model.glossary?.entries.count ?? 0)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("translate.glossary.edit") { editingGlossary = true }.disabled(disabled || model.glossaryName.isEmpty)
                if allowsSaveAs {
                    Button("translate.glossary.saveAs") {
                        newName = model.glossaryName
                        savingAs = true
                    }
                    .disabled(disabled || model.glossaryName.isEmpty)
                }
                if let extract {
                    Button("translate.glossary.extract", action: extract).disabled(!canExtract)
                }
            }
            .help(Text("translate.glossary.help"))
            if usesLLM {
                Toggle("translate.glossary.auto", isOn: $extractTerms).disabled(disabled)
            }
        }
    }

    /// Keeps the chosen glossary's entries under another name, which becomes the chosen one.
    private func saveAs() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var copy = model.glossary ?? TranslationGlossary(name: model.glossaryName, targetLanguage: target)
        copy.name = name
        Task {
            do { try await model.save(copy) } catch { NSAlert(error: error).runModal() }
        }
    }
}
