import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pickers for subtitle files and the folder that holds them.
enum SubtitleFilePanel {
    static let types: [UTType] = SubtitleFileReader.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.plainText]

    static func pickFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("localFile.panelTitle")
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Subtitle files and folders, several at once.
    static func pickFilesAndFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("files.panelTitle")
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func pickFolder(startingAt folder: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = AppLocalization.string("download.savePrompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A chosen file (its name above its folder) or an invitation to choose one, with the buttons that do so.
struct SubtitleFileSlot: View {
    let url: URL?
    var symbol = "doc.text"
    var emptyKey: LocalizedStringKey = "files.dropOne"
    var chooseKey: LocalizedStringKey = "localFile.choose"
    let choose: () -> Void
    var clear: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: url == nil ? "plus" : symbol, tint: url == nil ? .secondary : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let url {
                    Text(verbatim: url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                } else {
                    Text(emptyKey).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(url?.path ?? "")
            Spacer(minLength: 12)
            if url != nil, let clear {
                Button("localFile.clear", action: clear).controlSize(.small)
            }
            Button(chooseKey, action: choose)
        }
    }
}

/// One subtitle file, chosen with a panel or dropped on the row.
struct SubtitleFileRow: View {
    @Binding var url: URL?
    let symbol: String
    @State private var targeted = false

    var body: some View {
        SubtitleFileSlot(url: url, symbol: symbol, choose: { url = SubtitleFilePanel.pickFile() ?? url }, clear: { url = nil })
            .padding(10)
            .dropZoneBackground(targeted: targeted)
            .dropDestination(for: URL.self) { urls, _ in
                guard let file = urls.first(where: SubtitleFileScanner.isSubtitle) else { return false }
                url = file
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// Subtitle files dropped or added, folders included, kept in episode order.
struct SubtitleFileDropList: View {
    let titleKey: LocalizedStringKey
    @Binding var files: [URL]
    var disabled = false
    @State private var targeted = false

    var body: some View {
        SettingsCard(titleKey: titleKey) {
            if files.isEmpty {
                DropZoneLabel(symbol: "tray.and.arrow.down", textKey: "files.drop", targeted: targeted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(files, id: \.self) { url in
                            HStack(spacing: 10) {
                                Text(verbatim: EpisodeKey.parse(url.lastPathComponent)?.label ?? "–")
                                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                Text(verbatim: url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Button { files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(disabled)
                                    .accessibilityLabel(Text("files.remove"))
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 10) {
                Button("files.add") { add(SubtitleFilePanel.pickFilesAndFolders()) }
                Button("files.clear") { files = [] }.disabled(files.isEmpty)
                Spacer()
                if !files.isEmpty {
                    Text(AppLocalization.format("files.count", files.count)).font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(disabled)
        }
        .dropHighlight(targeted && !files.isEmpty)
        .dropDestination(for: URL.self) { urls, _ in
            guard !disabled else { return false }
            add(urls)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func add(_ urls: [URL]) {
        let added = SubtitleFileScanner.files(in: urls)
        guard !added.isEmpty else { return }
        files = SubtitleFileScanner.sorted(Array(Set(files.map(\.standardizedFileURL) + added)))
    }
}

/// Where written files go, how they are named and what happens to a file already there.
struct OutputOptionsSection: View {
    /// Folder path, or "" to write next to each source file.
    @Binding var folderPath: String
    @Binding var pattern: String
    @Binding var existing: OutputNaming.ExistingFile
    /// The name a sample source would get, to show what the pattern does.
    var example: String?
    var showsPattern = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("output.folder")
                Spacer(minLength: 12)
                Text(verbatim: folderPath.isEmpty ? AppLocalization.string("output.folder.source")
                     : (folderPath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                if !folderPath.isEmpty { Button("output.folder.reset") { folderPath = "" }.controlSize(.small) }
                Button("output.folder.choose") {
                    if let url = SubtitleFilePanel.pickFolder(startingAt: folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath)) {
                        folderPath = url.path
                    }
                }
            }
            if showsPattern {
                SettingsField("output.name") {
                    TextField(text: $pattern, prompt: Text(verbatim: "{name}")) { EmptyView() }
                        .textFieldStyle(.roundedBorder).frame(minWidth: 160, maxWidth: 320)
                }
                SettingsHint(key: "output.name.help")
                if let example { StatusLine(text: AppLocalization.format("output.name.example", example)) }
            }
            SettingsField("output.existing") {
                Picker("output.existing", selection: $existing) {
                    Text("output.existing.skip").tag(OutputNaming.ExistingFile.skip)
                    Text("output.existing.rename").tag(OutputNaming.ExistingFile.rename)
                    Text("output.existing.overwrite").tag(OutputNaming.ExistingFile.overwrite)
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}

/// Track 2 delay, line-up tolerance, line order, format and layout of a merge.
struct MergeOptionsSection: View {
    @Binding var options: BilingualMergeOptions
    /// Shows the delay field (and its auto-detect button, when given).
    var showsDelay = true
    var detect: (() -> Void)?
    var detecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsDelay {
                SettingsField("download.delay.secondary") {
                    if detecting { ProgressView().controlSize(.small) }
                    if let detect { Button("merge.detect", action: detect).disabled(detecting) }
                    MillisecondsField(value: $options.secondaryOffsetMs)
                }
            }
            SnapToleranceSlider(tolerance: $options.tolerance)
            SettingsHint(key: "merge.snap.help")
            Divider()
            SettingsField("merge.layout") {
                Picker("merge.layout", selection: $options.layout) {
                    Text("merge.layout.combined").tag(BilingualMergeOptions.Layout.combined)
                    Text("merge.layout.separate").tag(BilingualMergeOptions.Layout.separate)
                }
                .labelsHidden().fixedSize()
            }
            SettingsField("merge.format") {
                Picker("merge.format", selection: $options.format) {
                    Text(verbatim: "SRT").tag(SubtitleOutputFormat.srt)
                    Text(verbatim: "ASS").tag(SubtitleOutputFormat.ass)
                }
                // Two short segments draw wider than the size the control reports, so `fixedSize` lets it spill past
                // the card's edge; this is the width it draws at.
                .pickerStyle(.segmented).labelsHidden().frame(width: 100)
            }
            if options.layout == .combined {
                Toggle("merge.secondaryOnTop", isOn: $options.secondaryOnTop)
            }
            SettingsHint(key: options.layout == .combined ? (options.format == .ass ? "merge.ass.help" : "merge.combined.help")
                         : "merge.separate.help")
        }
    }
}

/// Merge settings kept between launches.
struct MergePreferences: DynamicProperty {
    @AppStorage("mergeSnapToleranceMs") var tolerance = 500
    @AppStorage("mergeSecondaryOnTop") var secondaryOnTop = false
    @AppStorage("mergeFormat") var format = SubtitleOutputFormat.srt
    @AppStorage("mergeLayout") var layout = BilingualMergeOptions.Layout.combined

    /// The kept settings as merge options, with `offset` for Track 2.
    func options(offset: Int = 0) -> BilingualMergeOptions {
        BilingualMergeOptions(tolerance: tolerance, secondaryOffsetMs: offset, secondaryOnTop: secondaryOnTop, format: format, layout: layout)
    }

    func save(_ options: BilingualMergeOptions) {
        if tolerance != options.tolerance { tolerance = options.tolerance }
        if secondaryOnTop != options.secondaryOnTop { secondaryOnTop = options.secondaryOnTop }
        if format != options.format { format = options.format }
        if layout != options.layout { layout = options.layout }
    }
}
