import SwiftUI

/// Shows a prompt template and the whole prompt it makes; the user's own templates can be edited, built-in ones copied.
struct LLMPromptEditorView: View {
    @State private var template: LLMPromptTemplate
    @State private var preview = Preview.translation
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("translationTarget") private var target = ""
    let configuration: LLMConfiguration
    let isSaved: Bool
    let onSave: (LLMPromptTemplate) -> Void
    let onDelete: (LLMPromptTemplate) -> Void

    private enum Preview: Hashable { case translation, terms }

    init(template: LLMPromptTemplate, configuration: LLMConfiguration, isSaved: Bool,
         onSave: @escaping (LLMPromptTemplate) -> Void, onDelete: @escaping (LLMPromptTemplate) -> Void) {
        _template = State(initialValue: template)
        self.configuration = configuration
        self.isSaved = isSaved
        self.onSave = onSave
        self.onDelete = onDelete
    }

    /// The languages of the preview: the translation card's target, from English (or into English, from Japanese).
    private var languages: (from: String, to: String) {
        let language = Locale.Language(identifier: target.isEmpty ? SubtitleTranslator.defaultTarget(source: nil) : target)
        let from = Locale.Language(identifier: language.languageCode == .english ? "ja" : "en")
        return (LLMSubtitleTranslationSession.englishName(from), LLMSubtitleTranslationSession.englishName(language))
    }

    private var fullPrompt: String {
        let (from, to) = languages
        return preview == .translation
            ? LLMSubtitleTranslationSession.translationPrompt(template, from: from, to: to, configuration: configuration)
            : LLMSubtitleTranslationSession.termPrompt(from: from, to: to, configuration: configuration)
    }

    private var canSave: Bool {
        !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !template.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(template.isBuiltIn ? "llm.prompt.builtInTitle" : "llm.prompt.editTitle").font(.title3.bold())
            if template.isBuiltIn {
                Text(verbatim: template.title).font(.headline)
                ScrollView {
                    Text(verbatim: template.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 120)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                TextField("llm.prompt.name", text: $template.name)
                TextEditor(text: $template.text)
                    .font(.body)
                    .frame(height: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            SettingsHint(key: "llm.prompt.placeholders")
            Divider()
            HStack {
                Text("llm.prompt.preview").font(.headline)
                Spacer()
                Picker("llm.prompt.preview", selection: $preview) {
                    Text("llm.prompt.preview.translation").tag(Preview.translation)
                    Text("llm.prompt.preview.terms").tag(Preview.terms)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ScrollView {
                Text(verbatim: fullPrompt).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(minHeight: 200)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text(AppLocalization.format("llm.prompt.preview.caption", languages.from, languages.to))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if template.isBuiltIn {
                    Button("llm.prompt.duplicate") {
                        template = LLMPromptTemplate(id: UUID().uuidString, name: AppLocalization.format("llm.prompt.copyName", template.title),
                                                     text: template.text)
                    }
                } else if isSaved {
                    Button("llm.prompt.delete", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                if template.isBuiltIn {
                    Button("llm.prompt.close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("common.cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("llm.prompt.save") {
                        template.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(template)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 600)
        .confirmationDialog(Text(AppLocalization.format("llm.prompt.delete.confirm", template.name)), isPresented: $confirmingDelete) {
            Button("llm.prompt.delete", role: .destructive) {
                onDelete(template)
                dismiss()
            }
        }
    }
}
