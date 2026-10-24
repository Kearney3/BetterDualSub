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
                          "ControlCenterView.swift", "ShortcutSettingsView.swift",
                          "Info.plist", "Localizable.xcstrings", "ThirdPartyNotices.txt",
                          "BilingualExportView.swift", "NowPlayingView.swift", "LoadSubtitlesView.swift", "LocalSubtitleFileView.swift",
                          "ManualControlBar.swift", "SettingsComponents.swift", "SubtitleAlignView.swift",
                          "SyncStatusView.swift", "SubtitleTranslationView.swift", "TranslationSettingsView.swift", "GlossaryEditorView.swift",
                          "UpdateChecker.swift", "ViewingSessionViews.swift", "SubtitleScreenSettings.swift",
                          "MediaRemotePlaybackClient.swift", "SubtitleManager.swift", "OnboardingViews.swift"],
                sources: ["SubtitleDocument.swift", "MovieSubtitleDownloader.swift", "MovpkgSubtitleExtractor.swift", "VideoSubtitleExtractor.swift",
                           "SubtitleTranslationPlan.swift", "PlaybackTracking.swift",
                           "AppVersion.swift", "ViewingSession.swift", "PlaybackCoordinator.swift",
                           "Localization.swift", "SubtitleTranslator.swift", "SubtitleTranslationSession.swift",
                           "SubtitleSentenceGrouping.swift", "SubtitleTranslationSplitter.swift", "TranslationGlossary.swift",
                           "LLMTranslationClient.swift", "LLMSubtitleTranslationSession.swift", "KeychainStore.swift"]),
        .testTarget(name: "BetterDualSubCoreTests", dependencies: ["BetterDualSubCore"], path: "Tests")
    ]
)
