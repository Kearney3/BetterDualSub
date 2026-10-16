import SwiftUI
import AppKit
import Translation
import UniformTypeIdentifiers

/// Creates or replaces Track 2 with an on-device translation of Track 1.
struct SubtitleTranslationCard: View {
    @EnvironmentObject private var manager: SubtitleManager
    @ObservedObject private var translator = SubtitleTranslator.shared
    @AppStorage("translationTarget") private var target = ""
    @State private var languages: [TranslationLanguage] = []
    @State private var plan: SubtitleTranslationPlan?
    @State private var source: Locale.Language?
    /// Set only when a language download is needed; `.translationTask` then offers it.
    @State private var download: TranslationSession.Configuration?
    @State private var showPreview = false

    /// The translator's state, unless it belongs to subtitles that have since been replaced.
    private var phase: SubtitleTranslator.Phase {
        translator.loadID == manager.loadID ? translator.phase : .idle
    }

    var body: some View {
        SettingsCard(titleKey: "translate.title") {
            SettingsHint(key: "translate.help")
            HStack(spacing: 10) {
                Text(AppLocalization.format("translate.source",
                                            source.map { SubtitleTranslator.displayName($0) } ?? AppLocalization.string("translate.source.unknown")))
                Spacer()
                Picker("translate.target", selection: $target) {
                    ForEach(languages) { Text(verbatim: $0.name).tag($0.id) }
                }
                .fixedSize()
                .disabled(translator.isBusy || languages.isEmpty)
            }
            HStack(spacing: 10) {
                Button(manager.trackNames.count > 1 ? "translate.action.replace" : "translate.action.create", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(translator.isBusy || source == nil || plan?.sources.isEmpty != false || target.isEmpty)
                if translator.isBusy {
                    Button("common.cancel") { translator.cancel() }
                }
            }
            status
        }
        .translationTask(download) { session in
            do {
                try await session.prepareTranslation()
                await translator.downloadFinished(error: nil, manager: manager)
            } catch {
                await translator.downloadFinished(error: error, manager: manager)
            }
        }
        .task(id: manager.loadID) {
            showPreview = false
            guard let document = manager.primaryDocument else { plan = nil; source = nil; return }
            let plan = SubtitleTranslationPlan(document: document)
            self.plan = plan
            source = plan.dominantLanguage.map(Locale.Language.init(identifier:))
            if languages.isEmpty { languages = await SubtitleTranslator.languages() }
            if !languages.contains(where: { $0.id == target }) || source?.languageCode == Locale.Language(identifier: target).languageCode {
                target = SubtitleTranslator.defaultTarget(source: source)
            }
        }
        .onDisappear {
            // The download offer belongs to this view; without it the request could never finish.
            if download != nil, phase == .preparing { translator.cancel() }
            download = nil
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
        case .translating(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text(AppLocalization.format("translate.status.progress", done, total)).font(.callout).foregroundStyle(.secondary)
            }
        case .finished(let lines, let language):
            StatusLine(text: AppLocalization.format("translate.status.done", lines, language))
            HStack(spacing: 10) {
                Button(showPreview ? "translate.preview.hide" : "translate.preview.show") { showPreview.toggle() }
                Button("translate.export", action: export)
            }
            .controlSize(.small)
            if showPreview, let document = translator.result?.document {
                TranslationPreviewList(translated: document.items, original: manager.primaryDocument?.items ?? [])
            }
        case .failed(let message):
            StatusLine(text: message, isError: true)
        case .cancelled:
            StatusLine(text: AppLocalization.string("download.status.cancelled"))
        }
    }

    private func start() {
        guard let plan, let source, !target.isEmpty else { return }
        let target = Locale.Language(identifier: target)
        Task {
            guard let configuration = await translator.start(plan: plan, source: source, target: target, manager: manager) else { return }
            // An unchanged configuration does not run the task again unless it is invalidated.
            if download == configuration { download?.invalidate() } else { download = configuration }
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

/// The translated Track 2, each line above the Track 1 line it came from.
private struct TranslationPreviewList: View {
    let translated: [SubtitleItem]
    let original: [SubtitleItem]

    var body: some View {
        // Translated cues keep Track 1's timing, so a cue's times find the line it translates.
        let sources = Dictionary(original.map { ("\($0.startMs)-\($0.endMs)", $0.text) }, uniquingKeysWith: { first, _ in first })
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(translated, id: \.self) { cue in
                    HStack(alignment: .top, spacing: 10) {
                        Text(verbatim: ManualControlBar.format(cue.startMs)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: cue.text.replacingOccurrences(of: "\n", with: " "))
                            if let source = sources["\(cue.startMs)-\(cue.endMs)"] {
                                Text(verbatim: SubtitleTranslationPlan.plainText(source)).font(.callout).foregroundStyle(.secondary)
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
