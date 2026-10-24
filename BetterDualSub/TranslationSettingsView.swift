import SwiftUI

/// Settings of the language model that can translate subtitles: a local server (Ollama, LM Studio) or an
/// OpenAI-compatible service.
struct TranslationSettingsView: View {
    @State private var configuration = LLMConfiguration.load()
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var testing = false
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
                        Menu {
                            ForEach(models, id: \.self) { model in Button(model) { configuration.model = model } }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(models.isEmpty)
                        .help(Text("llm.model.choose"))
                    }
                    SecureField("llm.apiKey", text: $apiKey,
                                prompt: Text(configuration.isOnThisMac ? "llm.apiKey.optional" : "llm.apiKey.required"))
                }
                .formStyle(.columns)
                HStack(spacing: 10) {
                    Button("llm.test", action: test).disabled(testing || configuration.endpoint == nil)
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
        }
        .onAppear { apiKey = configuration.apiKey ?? "" }
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

    private func test() {
        let client = LLMTranslationClient(configuration: configuration, apiKey: apiKey)
        testing = true
        testStatus = nil
        Task {
            defer { testing = false }
            do {
                let list = try await client.models()
                models = list
                if configuration.model.trimmingCharacters(in: .whitespaces).isEmpty, let first = list.first { configuration.model = first }
                testStatus = (AppLocalization.format("llm.test.ok", list.count), false)
            } catch {
                testStatus = (error.localizedDescription, true)
            }
        }
    }
}
