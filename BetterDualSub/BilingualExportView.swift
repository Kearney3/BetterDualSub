import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Standalone module: merges two local subtitle files into one bilingual SRT without loading anything for playback.
struct BilingualExportView: View {
    @State private var primaryURL: URL?
    @State private var secondaryURL: URL?
    @State private var secondaryDelay = 0
    @State private var status = ""
    @State private var error = ""

    private static let types: [UTType] = SubtitleFileReader.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.plainText]

    var body: some View {
        SettingsPage(descriptionKey: "bilingual.description") {
            SettingsCard(titleKey: "bilingual.primary.title") {
                fileRow(url: primaryURL, symbol: "text.bubble", choose: { primaryURL = pick() ?? primaryURL }, clear: { primaryURL = nil })
            }
            SettingsCard(titleKey: "bilingual.secondary.title") {
                fileRow(url: secondaryURL, symbol: "text.bubble.fill", choose: { secondaryURL = pick() ?? secondaryURL }, clear: { secondaryURL = nil })
                HStack(spacing: 10) {
                    Text("download.delay.secondary")
                    TextField("0", value: $secondaryDelay, format: .number).frame(width: 80).textFieldStyle(.roundedBorder)
                }
                SettingsHint(key: "bilingual.offset.help")
                Button("bilingual.export", action: export)
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryURL == nil || secondaryURL == nil)
            }
            if !status.isEmpty { StatusLine(text: status) }
            if !error.isEmpty { StatusLine(text: error, isError: true) }
        }
        .frame(minWidth: 560)
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in status = ""; error = "" }
    }

    private func fileRow(url: URL?, symbol: String, choose: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            if let url {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("localFile.clear", action: clear).controlSize(.small)
            } else {
                Spacer()
            }
            Button("localFile.choose", action: choose)
        }
    }

    private func pick() -> URL? {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("localFile.panelTitle")
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func export() {
        guard let primaryURL, let secondaryURL else { return }
        status = ""; error = ""
        let panel = NSSavePanel()
        panel.prompt = AppLocalization.string("movpkg.exportPrompt")
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.directoryURL = primaryURL.deletingLastPathComponent()
        panel.nameFieldStringValue = primaryURL.deletingPathExtension().lastPathComponent + ".bilingual.srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let first = try SubtitleFileReader.document(at: primaryURL)
            let second = try SubtitleFileReader.document(at: secondaryURL)
            let merged = try SubtitleDocument.bilingual(primary: first, secondary: second, secondaryOffsetMs: secondaryDelay)
            try merged.srt.write(to: url, atomically: true, encoding: .utf8)
            status = AppLocalization.format("bilingual.status.exported", merged.items.count)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
