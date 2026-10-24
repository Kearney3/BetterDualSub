import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Edits the names and terms of a glossary, which every translation of the show then uses.
struct GlossaryEditorView: View {
    @State private var glossary: TranslationGlossary
    @State private var selection = Set<GlossaryEntry.ID>()
    @Environment(\.dismiss) private var dismiss
    let onSave: (TranslationGlossary) -> Void

    init(glossary: TranslationGlossary, onSave: @escaping (TranslationGlossary) -> Void) {
        _glossary = State(initialValue: glossary)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("glossary.title").font(.title3.bold())
            TextField("glossary.name", text: $glossary.name)
            SettingsHint(key: "glossary.help")
            Table(glossary.entries, selection: $selection) {
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
                    let entry = GlossaryEntry(source: "", target: "")
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
                Button("glossary.export", action: exportTSV).disabled(glossary.entries.isEmpty)
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
        panel.allowedContentTypes = [.tabSeparatedText, .plainText, .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = TranslationGlossary.entries(fromTSV: try String(contentsOf: url, encoding: .utf8))
            for entry in imported {
                if let index = glossary.entries.firstIndex(where: { $0.source.caseInsensitiveCompare(entry.source) == .orderedSame }) {
                    glossary.entries[index].target = entry.target
                    glossary.entries[index].kind = entry.kind
                    glossary.entries[index].automatic = false
                } else {
                    glossary.entries.append(entry)
                }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func exportTSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tabSeparatedText]
        panel.nameFieldStringValue = (glossary.name.isEmpty ? "glossary" : glossary.name) + ".tsv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try glossary.tsv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
