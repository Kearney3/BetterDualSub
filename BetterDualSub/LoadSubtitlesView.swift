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
        case .episode: "film.stack"
        case .file: "doc.text"
        }
    }
}

/// The single entry for loading subtitles. Once a source loads them, the control center moves on to Now Playing.
struct LoadSubtitlesView: View {
    @AppStorage(LoadSource.storageKey) private var source = LoadSource.movie

    var body: some View {
        VStack(spacing: 0) {
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
            case .movie: MovieSubtitleDownloadView()
            case .episode: MovpkgSubtitleImportView()
            case .file: LocalSubtitleFileView()
            }
        }
    }
}
