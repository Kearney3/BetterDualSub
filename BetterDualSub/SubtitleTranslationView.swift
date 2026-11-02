import SwiftUI
import AppKit
import Translation
import UniformTypeIdentifiers

/// Creates or replaces Track 2 with a translation of Track 1, by the on-device translator or a language model.
struct SubtitleTranslationCard: View {
    @EnvironmentObject private var manager: SubtitleManager
    @ObservedObject private var translator = SubtitleTranslator.shared
    @StateObject private var settings = TranslationOptionsModel()
    /// Track 2 was to be translated right after loading, but a language or the model still has to be chosen.
    @State private var automaticStartBlocked = false
    @State private var plan: SubtitleTranslationPlan?
    /// Set only when a language download is needed; `.translationTask` then offers it.
    @State private var download: TranslationSession.Configuration?
    @State private var downloadRequestID: UUID?
    @State private var showPreview = false
    /// The load whose languages and plan are ready, so a translation asked for from elsewhere can start.
    @State private var readyLoadID: UUID?

    /// The translator's state, unless it belongs to subtitles that have since been replaced.
    private var phase: SubtitleTranslator.Phase {
        translator.loadID == manager.loadID ? translator.phase : .idle
    }

    /// Translation can start: languages chosen, something to translate, and a language model set up if one is used.
    private var canStart: Bool {
        !translator.isBusy && plan?.sources.isEmpty == false && settings.isReady
    }

    var body: some View {
        SettingsCard(titleKey: "translate.title") {
            TranslationOptionsSection(model: settings, disabled: translator.isBusy, extract: extract, canExtract: canStart)
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
            if automaticStartBlocked, phase == .idle {
                StatusLine(text: AppLocalization.string(settings.usesLLM && !settings.llm.isComplete
                                                        ? "translate.auto.needsModel" : "translate.auto.needsLanguage"))
            }
            status
        }
        .translationTask(download, action: SubtitleTranslationDownload(requestID: downloadRequestID, translator: translator, target: manager).prepare)
        .onChange(of: translator.isBusy) { _, busy in
            if !busy { download = nil; downloadRequestID = nil }
        }
        .task(id: manager.loadID) {
            showPreview = false
            readyLoadID = nil
            guard let document = manager.primaryDocument else { plan = nil; return }
            let plan = SubtitleTranslationPlan(document: document)
            self.plan = plan
            await settings.adopt(detected: plan.dominantLanguage.map(Locale.Language.init(identifier:)))
            settings.glossaryName = TranslationGlossary.seriesName(from: manager.loadedTitle.isEmpty ? "subtitle" : manager.loadedTitle)
            automaticStartBlocked = false
            readyLoadID = manager.loadID
            startIfRequested()
        }
        // Track 2 set to "translate" on Now Playing while these subtitles are already loaded.
        .onChange(of: translator.automaticLoadID) { _, _ in startIfRequested() }
        .onChange(of: translator.glossary) { _, updated in settings.adopt(glossary: updated) }
        .onDisappear {
            // The download offer belongs to this view; without it the request could never finish.
            if download != nil, phase == .preparing { translator.cancel() }
            download = nil
            downloadRequestID = nil
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
            if !translator.previewOnly, done > 0 { SettingsHint(key: "translate.status.live") }
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

    private func extract() {
        guard let plan, let source = settings.sourceLanguage, let target = settings.targetLanguage else { return }
        Task {
            let options = await settings.options(preview: false)
            guard let configuration = await translator.extractTerms(plan: plan, source: source, target: target, manager: manager,
                                                                    options: options) else { return }
            downloadRequestID = translator.pendingID
            if download == configuration { download?.invalidate() } else { download = configuration }
        }
    }

    private func startIfRequested() {
        guard readyLoadID == manager.loadID, translator.takeAutomaticStart(loadID: manager.loadID), !translator.isBusy else { return }
        if canStart { start(preview: false) } else { automaticStartBlocked = true }
    }

    private func start(preview: Bool) {
        guard let fullPlan = plan, let source = settings.sourceLanguage, let target = settings.targetLanguage else { return }
        Task {
            do {
                let options = await settings.options(preview: preview)
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
