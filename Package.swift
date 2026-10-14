// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BetterDualSubCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "BetterDualSubCore", targets: ["BetterDualSubCore"])],
    targets: [
        .target(name: "BetterDualSubCore", path: "BetterDualSub",
                exclude: ["ContentView.swift", "BetterDualSubApp.swift", "MovieSubtitleDownloadView.swift",
                          "MovpkgSubtitleImportView.swift", "SubtitleAppearanceView.swift",
                          "ControlCenterView.swift", "ShortcutSettingsView.swift", "Localization.swift",
                          "Info.plist", "Localizable.xcstrings", "ThirdPartyNotices.txt",
                          "BilingualExportView.swift", "NowPlayingView.swift", "LoadSubtitlesView.swift", "LocalSubtitleFileView.swift",
                          "ManualControlBar.swift", "SettingsComponents.swift", "SubtitleAlignView.swift",
                          "SyncStatusView.swift", "SubtitleTranslator.swift", "SubtitleTranslationView.swift"],
                sources: ["SubtitleDocument.swift", "MovieSubtitleDownloader.swift", "MovpkgSubtitleExtractor.swift",
                           "SubtitleTranslationPlan.swift", "PlaybackTracking.swift"]),
        .testTarget(name: "BetterDualSubCoreTests", dependencies: ["BetterDualSubCore"], path: "Tests")
    ]
)
