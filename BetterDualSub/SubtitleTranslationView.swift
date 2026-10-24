import SwiftUI
import AppKit
import Translation
import UniformTypeIdentifiers

/// Creates or replaces Track 2 with a translation of Track 1, by the on-device translator or a language model.
struct SubtitleTranslationCard: View {
    @EnvironmentObject private var manager: SubtitleManager
    @ObservedObject private var translator = SubtitleTranslator.shared
    @AppStorage("translationTarget") private var target = ""
    @AppStorage("translationEngine") private var engineID = "system"
    @AppStorage("translationExtractTerms") private var extractTerms = true
    @AppStorage("translationSubdivide") private var subdivide = true
    @AppStorage(LLMConfiguration.storageKey) private var llmData = Data()
    @State private var glossary: TranslationGlossary?
    @State private var glossaryName = ""
    @State private var glossaryNames: [String] = []
    @State private var editingGlossary = false
    @State private var languages: [TranslationLanguage] = []
    @State private var plan: SubtitleTranslationPlan?
    @State private var source: Locale.Language?
    @State private var sourceID = ""
    /// Set only when a language download is needed; `.translationTask` then offers it.
    @State private var download: TranslationSession.Configuration?
    @State private var downloadRequestID: UUID?
    @State private var showPreview = false

    /// The translator's state, unless it belongs to subtitles that have since been replaced.
    private var phase: SubtitleTranslator.Phase {
        translator.loadID == manager.loadID ? translator.phase : .idle
    }

    private var llm: LLMConfiguration {
        (try? JSONDecoder().decode(LLMConfiguration.self, from: llmData)) ?? LLMConfiguration()
    }

    private var usesLLM: Bool { engineID == "llm" }

    private var engine: SubtitleTranslationEngine { usesLLM ? .llm(llm) : .system }

    /// Translation can start: languages chosen, something to translate, and a language model set up if one is used.
    private var canStart: Bool {
        !translator.isBusy && !sourceID.isEmpty && plan?.sources.isEmpty == false && !target.isEmpty && (!usesLLM || llm.isComplete)
    }

    var body: some View {
        SettingsCard(titleKey: "translate.title") {
            SettingsHint(key: usesLLM ? (llm.isOnThisMac ? "translate.help.llmLocal" : "translate.help.llmRemote") : "translate.help")
            HStack(spacing: 10) {
                Picker("translate.engine", selection: $engineID) {
                    Text("translate.engine.system").tag("system")
                    Text(verbatim: AppLocalization.format("translate.engine.llm", llm.model.isEmpty ? llm.preset.name : "\(llm.preset.name) · \(llm.model)"))
                        .tag("llm")
                }
                .fixedSize()
                .disabled(translator.isBusy)
                Spacer()
                if usesLLM {
                    Button(llm.isComplete ? "translate.engine.settings" : "translate.engine.configure") { showControlCenterPage("translation") }
                }
            }
            if usesLLM, llm.isComplete, !llm.isOnThisMac {
                StatusLine(text: AppLocalization.format("translate.privacy.remote", llm.keychainAccount))
            }
            HStack(spacing: 10) {
                Picker("translate.source.choose", selection: $sourceID) {
                    Text("translate.source.unknown").tag("")
                    ForEach(languages) { Text(verbatim: $0.name).tag($0.id) }
                }
                .disabled(translator.isBusy || languages.isEmpty)
                Spacer()
                Picker("translate.target", selection: $target) {
                    ForEach(languages) { Text(verbatim: $0.name).tag($0.id) }
                }
                .fixedSize()
                .disabled(translator.isBusy || languages.isEmpty)
            }
            glossaryRow
            Toggle("translate.subdivide", isOn: $subdivide).disabled(translator.isBusy)
            HStack(spacing: 10) {
                Button("translate.sample") { start(preview: true) }
                    .disabled(!canStart)
                Button(manager.trackNames.count > 1 ? "translate.action.replace" : "translate.action.create") { start(preview: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                if manager.canUndoSecondary {
                    Button("translate.undo") { manager.undoSecondary(); translator.clearResult() }.disabled(translator.isBusy)
                }
                if translator.isBusy {
                    Button("common.cancel") { translator.cancel() }
                }
            }
            status
        }
        .translationTask(download, action: SubtitleTranslationDownload(requestID: downloadRequestID, translator: translator, target: manager).prepare)
        .onChange(of: translator.isBusy) { _, busy in
            if !busy { download = nil; downloadRequestID = nil }
        }
        .task(id: manager.loadID) {
            showPreview = false
            guard let document = manager.primaryDocument else { plan = nil; source = nil; return }
            let plan = SubtitleTranslationPlan(document: document)
            self.plan = plan
            source = plan.dominantLanguage.map(Locale.Language.init(identifier:))
            if languages.isEmpty { languages = await SubtitleTranslator.languages() }
            sourceID = source.flatMap { detected in
                languages.first { Locale.Language(identifier: $0.id).languageCode == detected.languageCode
                    && Locale.Language(identifier: $0.id).script == Locale.Language(identifier: detected.maximalIdentifier).script }?.id
                ?? languages.first { Locale.Language(identifier: $0.id).languageCode == detected.languageCode }?.id
            } ?? ""
            if !languages.contains(where: { $0.id == target }) || source?.languageCode == Locale.Language(identifier: target).languageCode {
                target = SubtitleTranslator.defaultTarget(source: source)
            }
            glossaryName = TranslationGlossary.seriesName(from: manager.loadedTitle.isEmpty ? "subtitle" : manager.loadedTitle)
        }
        .task(id: "\(glossaryName)\u{0}\(target)") { await loadGlossary() }
        .onChange(of: translator.glossary) { _, updated in
            if let updated, updated.name == glossaryName, updated.targetLanguage == target { glossary = updated }
        }
        .sheet(isPresented: $editingGlossary) {
            GlossaryEditorView(glossary: glossary ?? TranslationGlossary(name: glossaryName, targetLanguage: target)) { edited in
                Task {
                    do {
                        try await GlossaryStore.shared.save(edited)
                        glossaryName = edited.name
                        glossary = edited
                        await loadGlossary()
                    } catch { NSAlert(error: error).runModal() }
                }
            }
        }
        .onDisappear {
            // The download offer belongs to this view; without it the request could never finish.
            if download != nil, phase == .preparing { translator.cancel() }
            download = nil
            downloadRequestID = nil
        }
    }

    /// The show's glossary for the target language: its name, size, and the ways to fill it.
    private var glossaryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("translate.glossary", selection: $glossaryName) {
                    ForEach(Array(Set(glossaryNames + [glossaryName])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) {
                        Text(verbatim: $0).tag($0)
                    }
                }
                .fixedSize()
                .disabled(translator.isBusy)
                Text(AppLocalization.format("glossary.count", glossary?.entries.count ?? 0)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("translate.glossary.edit") { editingGlossary = true }.disabled(translator.isBusy || glossaryName.isEmpty)
                if usesLLM {
                    Button("translate.glossary.extract", action: extract).disabled(!canStart)
                }
            }
            .help(Text("translate.glossary.help"))
            if usesLLM {
                Toggle("translate.glossary.auto", isOn: $extractTerms).disabled(translator.isBusy)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("translate.status.preparing").foregroundStyle(.secondary)
            }
        case .extractingTerms(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text(AppLocalization.format("translate.status.extracting", done, total)).font(.callout).foregroundStyle(.secondary)
            }
        case .termsExtracted(let added):
            StatusLine(text: AppLocalization.format("translate.glossary.extracted", added))
        case .translating(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text(AppLocalization.format("translate.status.progress", done, total)).font(.callout).foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("translate.status.checking").foregroundStyle(.secondary)
            }
        case .finished(let lines, let language):
            StatusLine(text: AppLocalization.format(translator.previewOnly ? "translate.sample.done" : "translate.status.done", lines, language))
            if translator.unresolvedTerms > 0 {
                StatusLine(text: AppLocalization.format("translate.status.unresolved", translator.unresolvedTerms), isError: true)
            }
            HStack(spacing: 10) {
                Button(showPreview ? "translate.preview.hide" : "translate.preview.show") { showPreview.toggle() }
                Button("translate.export", action: export)
            }
            .controlSize(.small)
            if (showPreview || translator.previewOnly), let document = translator.result?.document {
                TranslationPreviewList(translated: document.items, original: manager.primaryDocument?.items ?? [])
            }
        case .failed(let message):
            StatusLine(text: message, isError: true)
        case .cancelled:
            StatusLine(text: AppLocalization.string("download.status.cancelled"))
        }
    }

    private func options(preview: Bool) -> SubtitleTranslationOptions {
        SubtitleTranslationOptions(engine: engine, glossary: glossary ?? TranslationGlossary(name: glossaryName, targetLanguage: target),
                                   extractTerms: usesLLM && extractTerms && !preview, subdivide: subdivide)
    }

    private func loadGlossary() async {
        guard !glossaryName.isEmpty, !target.isEmpty else { glossary = nil; return }
        let name = glossaryName, language = target
        let loaded = try? await GlossaryStore.shared.load(name: name, targetLanguage: language)
        let names = await GlossaryStore.shared.names(targetLanguage: language)
        guard name == glossaryName, language == target else { return }
        glossary = loaded ?? TranslationGlossary(name: name, targetLanguage: language)
        glossaryNames = names
    }

    private func extract() {
        guard let plan, !sourceID.isEmpty, !target.isEmpty else { return }
        let source = Locale.Language(identifier: sourceID), target = Locale.Language(identifier: target)
        let options = options(preview: false)
        Task { await translator.extractTerms(plan: plan, source: source, target: target, manager: manager, options: options) }
    }

    private func start(preview: Bool) {
        guard let fullPlan = plan, !sourceID.isEmpty, !target.isEmpty else { return }
        let source = Locale.Language(identifier: sourceID)
        let target = Locale.Language(identifier: target)
        let options = options(preview: preview)
        Task {
            do {
                let plan = try (preview ? fullPlan.preview() : fullPlan)
                guard let configuration = await translator.start(plan: plan, source: source, target: target, manager: manager,
                                                                 preview: preview, options: options) else { return }
                downloadRequestID = translator.pendingID
                // An unchanged configuration does not run the task again unless it is invalidated.
                if download == configuration { download?.invalidate() } else { download = configuration }
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private func export() {
        guard let (document, language) = translator.result else { return }
        let panel = NSSavePanel()
        panel.prompt = AppLocalization.string("movpkg.exportPrompt")
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = (manager.loadedTitle.isEmpty ? "subtitle" : manager.loadedTitle) + ".\(language.minimalIdentifier).srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.srt.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The translated Track 2, each line above the Track 1 lines it came from.
private struct TranslationPreviewList: View {
    let translated: [SubtitleItem]
    let original: [SubtitleItem]

    /// Translated cues lie within the Track 1 cues they translate (a long one may be split, an empty one merged into
    /// its neighbour), so the source of a cue is the Track 1 text it overlaps.
    private func source(of cue: SubtitleItem) -> String? {
        let lines = original.filter { $0.startMs < cue.endMs && $0.endMs > cue.startMs }.map { SubtitleTranslationPlan.plainText($0.text) }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(translated, id: \.self) { cue in
                    HStack(alignment: .top, spacing: 10) {
                        Text(verbatim: ManualControlBar.format(cue.startMs)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: cue.text.replacingOccurrences(of: "\n", with: " "))
                            if let source = source(of: cue) {
                                Text(verbatim: source).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8)
                }
            }
        }
        .frame(height: 280)
    }
}
