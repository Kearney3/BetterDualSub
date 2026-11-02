import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Edits the names and terms of a glossary, which every translation of the show then uses.
struct GlossaryEditorView: View {
    @State private var glossary: TranslationGlossary
    @State private var selection = Set<GlossaryEntry.ID>()
    /// Shows only names (people, places, organizations) or only terms; nil shows everything.
    @State private var filter: Filter = .all
    @Environment(\.dismiss) private var dismiss
    let onSave: (TranslationGlossary) -> Void

    init(glossary: TranslationGlossary, onSave: @escaping (TranslationGlossary) -> Void) {
        _glossary = State(initialValue: glossary)
        self.onSave = onSave
    }

    private enum Filter: String, CaseIterable {
        case all, names, terms

        func includes(_ kind: GlossaryEntry.Kind) -> Bool {
            switch self {
            case .all: true
            case .names: kind != .term
            case .terms: kind == .term
            }
        }
    }

    private var shown: [GlossaryEntry] { glossary.entries.filter { filter.includes($0.kind) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("glossary.title").font(.title3.bold())
            TextField("glossary.name", text: $glossary.name)
            SettingsHint(key: "glossary.help")
            Picker("glossary.filter", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text(LocalizedStringKey("glossary.filter.\($0.rawValue)")).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Table(shown, selection: $selection) {
                TableColumn("glossary.source") { entry in TextField("glossary.source", text: binding(entry.id, \.source)).labelsHidden() }
                TableColumn("glossary.target") { entry in TextField("glossary.target", text: binding(entry.id, \.target)).labelsHidden() }
                TableColumn("glossary.kind") { entry in
                    Picker("glossary.kind", selection: binding(entry.id, \.kind)) {
                        ForEach(GlossaryEntry.Kind.allCases, id: \.self) { Text(LocalizedStringKey("glossary.kind.\($0.rawValue)")).tag($0) }
                    }
                    .labelsHidden()
                }
                .width(110)
                TableColumn("glossary.note") { entry in
                    HStack(spacing: 4) {
                        TextField("glossary.note", text: binding(entry.id, \.note)).labelsHidden()
                        if entry.automatic {
                            Image(systemName: "sparkles").foregroundStyle(.secondary).help(Text("glossary.automatic"))
                        }
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Button {
                    let entry = GlossaryEntry(source: "", target: "", kind: filter == .names ? .person : .term)
                    glossary.entries.append(entry)
                    selection = [entry.id]
                } label: { Image(systemName: "plus") }
                .help(Text("glossary.add"))
                Button {
                    glossary.entries.removeAll { selection.contains($0.id) }
                    selection = []
                } label: { Image(systemName: "minus") }
                .disabled(selection.isEmpty)
                .help(Text("glossary.remove"))
                Text(AppLocalization.format("glossary.count", glossary.entries.count)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("glossary.import", action: importTSV)
                Menu("glossary.export") {
                    Button("glossary.export.tsv") { export(json: false) }
                    Button("glossary.export.json") { export(json: true) }
                }
                .fixedSize()
                .disabled(glossary.entries.isEmpty)
                Button("common.cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("glossary.save") {
                    glossary.name = glossary.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    glossary.entries = glossary.entries.filter { !$0.source.trimmingCharacters(in: .whitespaces).isEmpty }
                    onSave(glossary)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(glossary.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
    }

    /// Editing a field makes the entry the user's own, so later automatic terms never replace it.
    private func binding<Value>(_ id: GlossaryEntry.ID, _ keyPath: WritableKeyPath<GlossaryEntry, Value>) -> Binding<Value> {
        Binding {
            // A removed row may still be drawn once; it reads as empty.
            (glossary.entries.first { $0.id == id } ?? GlossaryEntry(source: "", target: ""))[keyPath: keyPath]
        } set: { value in
            guard let index = glossary.entries.firstIndex(where: { $0.id == id }) else { return }
            glossary.entries[index][keyPath: keyPath] = value
            glossary.entries[index].automatic = false
        }
    }

    /// Imported entries replace those with the same source and add the rest.
    private func importTSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tabSeparatedText, .plainText, .commaSeparatedText, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = TranslationGlossary.entries(fromJSON: data)
                ?? TranslationGlossary.entries(fromTSV: String(decoding: data, as: UTF8.self))
            glossary.importEntries(imported)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Exports what the filter shows, so names and terms can be kept as separate libraries.
    private func export(json: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [json ? .json : .tabSeparatedText]
        let base = glossary.name.isEmpty ? "glossary" : glossary.name
        panel.nameFieldStringValue = base + (filter == .all ? "" : "." + filter.rawValue) + (json ? ".json" : ".tsv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var part = glossary
        part.entries = shown
        do {
            if json {
                guard let data = part.json else { return }
                try data.write(to: url, options: .atomic)
            } else {
                try part.tsv.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
