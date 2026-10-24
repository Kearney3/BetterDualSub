import SwiftUI

/// Where subtitles are loaded from; each source has its own panel on the Load Subtitles page.
enum LoadSource: String, CaseIterable, Identifiable {
    case file, episode, movie

    static let storageKey = "loadSource"
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .movie: "load.source.movie"
        case .episode: "load.source.episode"
        case .file: "load.source.file"
        }
    }

    var symbol: String {
        switch self {
        case .movie: "link"
        case .episode: "film"
        case .file: "doc.text"
        }
    }
}

/// The single entry for loading subtitles. Once a source loads them, the control center moves on to Now Playing.
struct LoadSubtitlesView: View {
    @AppStorage(LoadSource.storageKey) private var source = LoadSource.file
    @State private var inputURLs: [URL] = []
    @State private var input = ""
    @State private var inputError = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("load.detect.placeholder", text: $input).textFieldStyle(.roundedBorder).onSubmit(openInput)
                    Button("load.detect.open", action: openInput).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(inputError ? "load.detect.unsupported" : "load.detect.help")
                    .font(.caption).foregroundStyle(inputError ? Color.orange : Color.secondary)
                if inputError {
                    HStack {
                        Button("load.source.file") { source = .file }
                        Button("load.source.episode") { source = .episode }
                    }.controlSize(.small)
                }
            }
            .padding(.horizontal, 28).padding(.top, 20)
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
            .dropDestination(for: URL.self) { urls, _ in route(urls); return !inputError }
            Picker("nav.load", selection: $source) {
                ForEach(LoadSource.allCases) { source in
                    Label(LocalizedStringKey(source.titleKey), systemImage: source.symbol).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)

            switch source {
            case .movie: MovieSubtitleDownloadView(inputURLs: $inputURLs)
            case .episode: MovpkgSubtitleImportView(inputURLs: $inputURLs)
            case .file: LocalSubtitleFileView(inputURLs: $inputURLs)
            }
        }
    }

    private func openInput() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = value.hasPrefix("/") || value.hasPrefix("~/")
            ? URL(fileURLWithPath: (value as NSString).expandingTildeInPath) : URL(string: value)
        route(url.map { [$0] } ?? [])
    }

    private func route(_ urls: [URL]) {
        inputError = false
        switch SubtitleInput(urls: urls) {
        case .movie: source = .movie
        case .package: source = .episode
        case .files: source = .file
        case .unsupported: inputError = true; return
        }
        inputURLs = urls
    }
}
