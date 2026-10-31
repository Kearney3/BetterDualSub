import SwiftUI
import AppKit
import Translation

/// Tool page: translates many subtitle files (a season, say) with the settings of the Now Playing translation card
/// and one shared glossary, and writes the translations and/or bilingual files.
struct BatchTranslationView: View {
    /// Kept for the app's lifetime like the batch itself, so the chosen glossary survives leaving the page mid-run.
    private static let settings = TranslationOptionsModel()

    @ObservedObject private var batch = SubtitleBatchTranslator.shared
    @ObservedObject private var settings = Self.settings
    @AppStorage("batchWriteTranslation") private var writeTranslation = true
    @AppStorage("batchWriteBilingual") private var writeBilingual = false
    @AppStorage("batchBilingualFormat") private var bilingualFormat = SubtitleOutputFormat.srt
    @AppStorage("batchSecondaryOnTop") private var secondaryOnTop = false
    @AppStorage("batchFolder") private var folderPath = ""
    @AppStorage("batchPattern") private var pattern = "{name}.{lang}"
    @AppStorage("batchBilingualPattern") private var bilingualPattern = "{name}.bilingual"
    @AppStorage("batchExisting") private var existing = OutputNaming.ExistingFile.skip
    @State private var error = ""

    private var files: Binding<[URL]> {
        Binding(get: { batch.items.map(\.url) }, set: { batch.setFiles($0) })
    }

    private var outputs: SubtitleBatchTranslator.Outputs {
        var bilingual = BilingualMergeOptions()
        bilingual.format = bilingualFormat
        bilingual.secondaryOnTop = secondaryOnTop
        return SubtitleBatchTranslator.Outputs(translation: writeTranslation, bilingual: writeBilingual ? bilingual : nil,
                                               folder: folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath),
                                               translationPattern: pattern, bilingualPattern: bilingualPattern, existing: existing)
    }

    private var canStart: Bool {
        !batch.isRunning && settings.isReady && (writeTranslation || writeBilingual)
            && batch.items.contains { !$0.status.isFinished }
    }

    var body: some View {
        SettingsPage(descriptionKey: "batch.description") {
            SubtitleFileDropList(titleKey: "batch.files.title", files: files, disabled: batch.isRunning)
            SettingsCard(titleKey: "batch.translate.title") {
                TranslationOptionsSection(model: settings, disabled: batch.isRunning, allowsSaveAs: true, forFiles: true)
                SettingsHint(key: "batch.glossary.help")
            }
            outputCard
            runCard
        }
        .frame(minWidth: 560)
        .translationTask(batch.download, action: SubtitleTranslationDownload(requestID: batch.pendingID, translator: batch.translator,
                                                                           target: batch.currentTarget).prepare)
        .task(id: batch.items.first?.url) { await adoptFirstFile() }
        .onChange(of: batch.glossary) { _, updated in settings.adopt(glossary: updated) }
        .onDisappear {
            // A language download is offered by this page; without it the run could never go on.
            if batch.download != nil { batch.cancel() }
        }
    }

    private var outputCard: some View {
        SettingsCard(titleKey: "batch.output.title") {
            Toggle("batch.output.translation", isOn: $writeTranslation)
            if writeTranslation {
                HStack(spacing: 10) {
                    Text("output.name")
                    TextField("{name}.{lang}", text: $pattern).textFieldStyle(.roundedBorder)
                }
                .padding(.leading, 20)
            }
            Toggle("batch.output.bilingual", isOn: $writeBilingual)
            if writeBilingual {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("output.name")
                        TextField("{name}.bilingual", text: $bilingualPattern).textFieldStyle(.roundedBorder)
                        Picker("merge.format", selection: $bilingualFormat) {
                            Text(verbatim: "SRT").tag(SubtitleOutputFormat.srt)
                            Text(verbatim: "ASS").tag(SubtitleOutputFormat.ass)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    Toggle("batch.output.translationOnTop", isOn: $secondaryOnTop)
                }
                .padding(.leading, 20)
            }
            SettingsHint(key: "output.name.help")
            if let first = batch.items.first?.url {
                let names = exampleNames(for: first)
                if !names.isEmpty { StatusLine(text: AppLocalization.format("output.name.example", names)) }
            }
            Divider()
            OutputOptionsSection(folderPath: $folderPath, pattern: $pattern, existing: $existing, showsPattern: false)
        }
        .disabled(batch.isRunning)
    }

    private var runCard: some View {
        SettingsCard {
            HStack(spacing: 10) {
                Button("batch.start", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                if batch.isRunning {
                    Button("common.cancel") { batch.cancel() }
                } else {
                    if batch.failedCount > 0 { Button("batch.retry", action: retry) }
                    if batch.items.contains(where: { $0.status != .waiting }) { Button("batch.reset") { batch.reset() } }
                }
                Spacer()
                if !batch.items.isEmpty {
                    Text(AppLocalization.format("batch.progress", batch.finishedCount, batch.items.count))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !batch.items.isEmpty, !settings.isReady {
                StatusLine(text: AppLocalization.string(settings.usesLLM && !settings.llm.isComplete
                                                        ? "batch.needsModel" : "batch.needsLanguage"))
            } else if !writeTranslation && !writeBilingual {
                StatusLine(text: AppLocalization.string("batch.needsOutput"))
            }
            if !error.isEmpty { StatusLine(text: error, isError: true) }
            if batch.items.contains(where: { $0.status != .waiting }) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(batch.items) { item in row(item) }
                }
            }
        }
    }

    private func row(_ item: SubtitleBatchTranslator.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(item.status).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting:
                    EmptyView()
                case .reading:
                    Text("batch.status.reading").font(.caption).foregroundStyle(.secondary)
                case .extractingTerms(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1))) {
                        Text(AppLocalization.format("translate.status.extracting", done, total)).font(.caption).foregroundStyle(.secondary)
                    }
                case .translating(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1))) {
                        Text(AppLocalization.format("translate.status.progress", done, total)).font(.caption).foregroundStyle(.secondary)
                    }
                case .checking:
                    Text("translate.status.checking").font(.caption).foregroundStyle(.secondary)
                case .done(let urls):
                    Text(verbatim: urls.map(\.lastPathComponent).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                case .skipped:
                    Text("batch.status.skipped").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(verbatim: message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                case .cancelled:
                    Text("download.status.cancelled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if case .done(let urls) = item.status, !urls.isEmpty {
                Button("batch.reveal") { NSWorkspace.shared.activateFileViewerSelecting(urls) }.controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: SubtitleBatchTranslator.Status) -> some View {
        switch status {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .reading, .extractingTerms, .translating, .checking: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    /// What the first file's outputs would be called, to show what the patterns do.
    private func exampleNames(for source: URL) -> String {
        let language = settings.targetLanguage.map(SubtitleTranslator.fileCode) ?? ""
        var names: [String] = []
        if writeTranslation { names.append(OutputNaming.fileName(pattern: pattern, source: source, language: language, format: .srt)) }
        if writeBilingual {
            names.append(OutputNaming.fileName(pattern: bilingualPattern, source: source, language: language, format: bilingualFormat))
        }
        return names.joined(separator: ", ")
    }

    /// The source language detected from the first file, and a glossary named after its show when none is chosen.
    private func adoptFirstFile() async {
        guard let url = batch.items.first?.url, !batch.isRunning else { return }
        let detected = try? await SubtitleBackgroundWork.run {
            SubtitleTranslationPlan(document: try SubtitleFileReader.document(at: url)).dominantLanguage
        }
        await settings.adopt(detected: detected.flatMap { $0 }.map(Locale.Language.init(identifier:)))
        if settings.glossaryName.isEmpty {
            settings.glossaryName = TranslationGlossary.seriesName(from: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func start() {
        guard let source = settings.sourceLanguage, let target = settings.targetLanguage else { return }
        error = ""
        let outputs = outputs
        Task {
            let options = await settings.options(preview: false)
            batch.start(source: source, target: target, options: options, outputs: outputs)
        }
    }

    private func retry() {
        guard let source = settings.sourceLanguage, let target = settings.targetLanguage else { return }
        let outputs = outputs
        Task {
            let options = await settings.options(preview: false)
            batch.retryFailed(source: source, target: target, options: options, outputs: outputs)
        }
    }
}
