import SwiftUI

/// Settings of the language model that can translate subtitles: a local server (Ollama, LM Studio) or an
/// OpenAI-compatible service.
struct TranslationSettingsView: View {
    @State private var configuration = LLMConfiguration.load()
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var testing = false
    @State private var choosingModel = false
    @State private var customPrompts = LLMPromptLibrary.custom()
    @State private var editingPrompt: LLMPromptTemplate?
    @State private var testStatus: (text: String, isError: Bool)?

    var body: some View {
        SettingsPage(descriptionKey: "llm.description") {
            SettingsCard(titleKey: "llm.service.title") {
                SettingsRow(symbol: "server.rack", tint: .indigo, titleKey: "llm.preset", subtitleKey: "llm.preset.help") {
                    Picker("llm.preset", selection: $configuration.preset) {
                        ForEach(LLMPreset.allCases) { Text(verbatim: $0.name).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider()
                Form {
                    TextField("llm.baseURL", text: $configuration.baseURL, prompt: Text(verbatim: LLMPreset.ollama.baseURL))
                    HStack {
                        TextField("llm.model", text: $configuration.model, prompt: Text("llm.model.prompt"))
                        Button { loadModels(choosing: true) } label: {
                            Label("llm.model.fetch", systemImage: "list.bullet")
                        }
                        .fixedSize()
                        .disabled(testing || configuration.endpoint == nil)
                        .help(Text("llm.model.choose"))
                        .popover(isPresented: $choosingModel, arrowEdge: .bottom) {
                            LLMModelPicker(models: models, selection: configuration.model) { model in
                                configuration.model = model
                                choosingModel = false
                            }
                        }
                    }
                    SecureField("llm.apiKey", text: $apiKey,
                                prompt: Text(configuration.isOnThisMac ? "llm.apiKey.optional" : "llm.apiKey.required"))
                }
                .formStyle(.columns)
                HStack(spacing: 10) {
                    Button("llm.test") { loadModels(choosing: false) }.disabled(testing || configuration.endpoint == nil)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let testStatus { StatusLine(text: testStatus.text, isError: testStatus.isError) }
                if configuration.endpoint == nil, !configuration.baseURL.isEmpty {
                    StatusLine(text: AppLocalization.string("llm.error.invalidURL"), isError: true)
                } else if configuration.endpoint != nil, !configuration.isOnThisMac {
                    StatusLine(text: AppLocalization.format("translate.privacy.remote", configuration.keychainAccount))
                }
                SettingsHint(key: "llm.local.help")
            }
            SettingsCard(titleKey: "llm.translation.title") {
                Stepper(value: $configuration.batchSize, in: LLMConfiguration.batchSizes, step: 5) {
                    Text(AppLocalization.format("llm.batchSize", configuration.batchSize))
                }
                Stepper(value: $configuration.contextLines, in: LLMConfiguration.contextSizes) {
                    Text(AppLocalization.format("llm.contextLines", configuration.contextLines))
                }
                HStack {
                    Text("llm.temperature")
                    Slider(value: $configuration.temperature, in: 0...1, step: 0.1)
                    Text(verbatim: String(format: "%.1f", configuration.temperature)).monospacedDigit().frame(width: 28)
                }
                SettingsHint(key: "llm.batch.help")
                Divider()
                Text("llm.instructions")
                TextEditor(text: $configuration.instructions)
                    .font(.body)
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                SettingsHint(key: "llm.instructions.help")
            }
            SettingsCard(titleKey: "llm.prompt.title") {
                HStack(spacing: 10) {
                    Picker("llm.prompt", selection: $configuration.promptID) {
                        Section("llm.prompt.builtIn") {
                            ForEach(LLMPromptTemplate.builtIn) { Text(verbatim: $0.title).tag($0.id) }
                        }
                        if !customPrompts.isEmpty {
                            Section("llm.prompt.custom") {
                                ForEach(customPrompts) { Text(verbatim: $0.title).tag($0.id) }
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button(selectedPrompt.isBuiltIn ? "llm.prompt.view" : "llm.prompt.edit") { editingPrompt = selectedPrompt }
                    Button("llm.prompt.new") {
                        editingPrompt = LLMPromptTemplate(id: UUID().uuidString, name: AppLocalization.string("llm.prompt.newName"),
                                                          text: LLMPromptTemplate.standard.text)
                    }
                }
                SettingsHint(key: "llm.prompt.help")
            }
            SettingsCard(titleKey: "llm.style.title") {
                Toggle("llm.translateNames", isOn: $configuration.translateNames)
                Toggle("llm.translatePlaces", isOn: $configuration.translatePlaces)
                SettingsHint(key: "llm.names.help")
                Divider()
                Toggle("llm.keepHonorifics", isOn: $configuration.keepHonorifics)
                Toggle("llm.softenProfanity", isOn: $configuration.softenProfanity)
            }
        }
        .onAppear {
            apiKey = configuration.apiKey ?? ""
            // A template deleted elsewhere falls back to the standard one, as translation does.
            if LLMPromptLibrary.template(id: configuration.promptID).id != configuration.promptID {
                configuration.promptID = LLMPromptTemplate.standard.id
            }
        }
        .sheet(item: $editingPrompt) { template in
            LLMPromptEditorView(template: template, configuration: configuration,
                                isSaved: customPrompts.contains { $0.id == template.id }, onSave: savePrompt, onDelete: deletePrompt)
        }
        .onChange(of: configuration) { old, new in
            if old.preset != new.preset {
                models = []
                testStatus = nil
                if new.preset != .custom { configuration.baseURL = new.preset.baseURL }
            }
            // Keys belong to a host, so a key for one service is never sent to another.
            if old.keychainAccount != new.keychainAccount { apiKey = new.apiKey ?? "" }
            new.save()
        }
        .onChange(of: apiKey) { _, key in
            KeychainStore.setPassword(key.trimmingCharacters(in: .whitespacesAndNewlines), account: configuration.keychainAccount)
        }
    }

    private var selectedPrompt: LLMPromptTemplate {
        (LLMPromptTemplate.builtIn + customPrompts).first { $0.id == configuration.promptID } ?? .standard
    }

    /// Adds or replaces the user's template and uses it.
    private func savePrompt(_ template: LLMPromptTemplate) {
        if let index = customPrompts.firstIndex(where: { $0.id == template.id }) {
            customPrompts[index] = template
        } else {
            customPrompts.append(template)
        }
        LLMPromptLibrary.saveCustom(customPrompts)
        configuration.promptID = template.id
    }

    private func deletePrompt(_ template: LLMPromptTemplate) {
        customPrompts.removeAll { $0.id == template.id }
        LLMPromptLibrary.saveCustom(customPrompts)
        if configuration.promptID == template.id { configuration.promptID = LLMPromptTemplate.standard.id }
    }

    /// Asks the service for its models, which also tests the connection; `choosing` then shows them to pick from.
    private func loadModels(choosing: Bool) {
        let client = LLMTranslationClient(configuration: configuration, apiKey: apiKey)
        testing = true
        testStatus = nil
        Task {
            defer { testing = false }
            do {
                let list = try await client.models()
                models = list
                if list.isEmpty {
                    testStatus = (AppLocalization.string("llm.model.none"), true)
                } else if choosing {
                    choosingModel = true
                } else {
                    if configuration.model.trimmingCharacters(in: .whitespaces).isEmpty, let first = list.first { configuration.model = first }
                    testStatus = (AppLocalization.format("llm.test.ok", list.count), false)
                }
            } catch {
                testStatus = (error.localizedDescription, true)
            }
        }
    }
}

/// The models a service offers, with a filter for long lists such as OpenAI's.
private struct LLMModelPicker: View {
    let models: [String]
    let selection: String
    let choose: (String) -> Void
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private static let rowHeight: CGFloat = 24

    private var shown: [String] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if models.count > 8 {
                TextField("llm.model.filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .onSubmit { if let first = shown.first { choose(first) } }
                    .padding(8)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.self) { model in
                        Button { choose(model) } label: {
                            HStack {
                                Text(verbatim: model).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                if model == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(max(shown.count, 1)) * Self.rowHeight + 8, 320))
        }
        .frame(width: 300)
        .onAppear { filterFocused = true }
    }
}
