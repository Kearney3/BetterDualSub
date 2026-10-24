import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LocalSubtitleFileView: View {
    @Binding var inputURLs: [URL]

    init(inputURLs: Binding<[URL]> = .constant([])) { self._inputURLs = inputURLs }
    @EnvironmentObject private var manager: SubtitleManager
    @State private var primaryURL: URL?
    @State private var secondaryURL: URL?
    @State private var primaryDelay = 0
    @State private var secondaryDelay = 0
    @State private var status = ""
    @State private var error = ""
    @State private var targeted = false
    @State private var secondaryTargeted = false
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()

    private static let types: [UTType] = SubtitleFileReader.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.plainText]

    var body: some View {
        SettingsPage(descriptionKey: "localFile.description") {
            SettingsCard(titleKey: "localFile.primary.title") {
                fileRow(url: primaryURL, symbol: "text.bubble", choose: { primaryURL = pick() }, clear: { primaryURL = nil })
                if primaryURL == nil { SettingsHint(key: "localFile.drop") }
            }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .dropDestination(for: URL.self) { urls, _ in
                // Two files dropped together are the two tracks, in the order given.
                let files = urls.filter(Self.isSubtitle)
                guard let first = files.first else { return false }
                primaryURL = first
                if files.count > 1 { secondaryURL = files[1] }
                return true
            } isTargeted: { targeted = $0 }

            if primaryURL != nil, secondaryURL != nil {
                HStack {
                    Spacer()
                    Button {
                        let first = primaryURL
                        primaryURL = secondaryURL
                        secondaryURL = first
                    } label: { Label("localFile.swap", systemImage: "arrow.up.arrow.down") }
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, -10)
            }

            SettingsCard(titleKey: "localFile.secondary.title") {
                fileRow(url: secondaryURL, symbol: "text.bubble.fill", choose: { secondaryURL = pick() }, clear: { secondaryURL = nil })
                SettingsHint(key: "localFile.secondary.help")
            }
            .overlay { if secondaryTargeted { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: Self.isSubtitle) else { return false }
                secondaryURL = url
                return true
            } isTargeted: { secondaryTargeted = $0 }

            SettingsCard(titleKey: "localFile.delay.title") {
                HStack(spacing: 10) {
                    Text("download.delay.primary")
                    TextField("0", value: $primaryDelay, format: .number).frame(width: 80)
                    Text("download.delay.secondary")
                    TextField("0", value: $secondaryDelay, format: .number).frame(width: 80)
                }.textFieldStyle(.roundedBorder)
                SettingsHint(key: "localFile.delay.help")
                HStack {
                    Button("localFile.load", action: load)
                        .buttonStyle(.borderedProminent)
                        .disabled(primaryURL == nil || busy)
                    if busy {
                        ProgressView().controlSize(.small)
                        Button("common.cancel", action: cancel)
                    }
                }
            }

            if !status.isEmpty { StatusLine(text: status) }
            if !error.isEmpty { StatusLine(text: error, isError: true) }
        }
        .frame(minWidth: 560)
        .onChange(of: primaryURL) { _, url in
            cancel()
            primaryDelay = url.flatMap(SubtitleFileReader.delayHint) ?? 0
            secondaryDelay = 0
        }
        .onChange(of: secondaryURL) { _, _ in cancel() }
        .onDisappear(perform: cancel)
        .onChange(of: manager.loadID) { _, _ in cancel() }
        .onAppear(perform: consumeInput)
        .onChange(of: inputURLs) { _, _ in consumeInput() }
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in status = ""; error = "" }
    }

    private func consumeInput() {
        guard case .files(let urls) = SubtitleInput(urls: inputURLs) else { return }
        primaryURL = urls.first
        secondaryURL = urls.count > 1 ? urls[1] : nil
        inputURLs = []
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
        (SubtitleFileReader.fileExtensions + ["txt"]).contains(url.pathExtension.lowercased())
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
        guard let primaryURL, !busy else { return }
        let secondaryURL = secondaryURL, firstDelay = primaryDelay, secondDelay = secondaryDelay
        let token = UUID(), loadID = manager.loadID
        generation = token
        busy = true
        status = ""; error = ""
        operation = Task {
            do {
                let (first, second) = try await SubtitleBackgroundWork.run {
                    (try SubtitleFileReader.document(at: primaryURL),
                     try secondaryURL.map { try SubtitleFileReader.document(at: $0) })
                }
                guard !Task.isCancelled, generation == token, manager.loadID == loadID else { return }
                let files = [primaryURL] + (secondaryURL.map { [$0] } ?? [])
                manager.load(primary: first, secondary: second,
                             title: primaryURL.deletingPathExtension().lastPathComponent,
                             names: files.map(\.lastPathComponent))
                if firstDelay != 0 || secondDelay != 0 {
                    manager.applyDelays(primary: firstDelay, secondaryExtra: secondDelay)
                }
                status = AppLocalization.format("localFile.status.loaded", first.items.count)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            guard generation == token else { return }
            busy = false
            operation = nil
        }
    }

    private func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        busy = false
    }
}
