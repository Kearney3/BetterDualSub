import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LocalSubtitleFileView: View {
    @EnvironmentObject private var manager: SubtitleManager
    @State private var primaryURL: URL?
    @State private var secondaryURL: URL?
    @State private var primaryDelay = 0
    @State private var secondaryDelay = 0
    @State private var status = ""
    @State private var error = ""
    @State private var targeted = false

    private static let types: [UTType] = ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) } + [.plainText]

    var body: some View {
        SettingsPage(descriptionKey: "localFile.description") {
            SettingsCard(titleKey: "localFile.primary.title") {
                fileRow(url: primaryURL, symbol: "text.bubble", choose: { primaryURL = pick() }, clear: { primaryURL = nil })
                if primaryURL == nil { SettingsHint(key: "localFile.drop") }
            }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: Self.isSubtitle) else { return false }
                primaryURL = url
                return true
            } isTargeted: { targeted = $0 }

            SettingsCard(titleKey: "localFile.secondary.title") {
                fileRow(url: secondaryURL, symbol: "text.bubble.fill", choose: { secondaryURL = pick() }, clear: { secondaryURL = nil })
                SettingsHint(key: "localFile.secondary.help")
            }

            SettingsCard(titleKey: "localFile.delay.title") {
                HStack(spacing: 10) {
                    Text("download.delay.primary")
                    TextField("0", value: $primaryDelay, format: .number).frame(width: 80)
                    Text("download.delay.secondary")
                    TextField("0", value: $secondaryDelay, format: .number).frame(width: 80)
                }.textFieldStyle(.roundedBorder)
                SettingsHint(key: "localFile.delay.help")
                Button("localFile.load", action: load)
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryURL == nil)
            }

            if !status.isEmpty { StatusLine(text: status) }
            if !error.isEmpty { StatusLine(text: error, isError: true) }
            LoadedSubtitleCard { EmptyView() }
        }
        .frame(minWidth: 560)
        .onChange(of: primaryURL) { _, url in
            if let url, let hint = SubtitleFileReader.delayHint(in: url) { primaryDelay = hint }
        }
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

    private nonisolated static func isSubtitle(_ url: URL) -> Bool {
        ["srt", "vtt", "txt"].contains(url.pathExtension.lowercased())
    }

    private func pick() -> URL? {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("localFile.panelTitle")
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func load() {
        guard let primaryURL else { return }
        status = ""; error = ""
        do {
            let first = try SubtitleFileReader.document(at: primaryURL)
            let second = try secondaryURL.map { try SubtitleFileReader.document(at: $0) }
            let files = [primaryURL] + (secondaryURL.map { [$0] } ?? [])
            manager.load(primary: first, secondary: second,
                         title: primaryURL.deletingPathExtension().lastPathComponent,
                         names: files.map(\.lastPathComponent))
            manager.applyDelays(primary: primaryDelay, secondaryExtra: secondaryDelay)
            status = AppLocalization.format("localFile.status.loaded", first.items.count)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
