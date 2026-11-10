// swift-tools-version: 6.2
import PackageDescription

// The same concurrency settings as the app target in BetterDualSub.xcodeproj, so the tests exercise the code as it
// ships: Swift 6, the main actor by default, and Xcode's "approachable concurrency" features.
let features: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]
let appSettings = features + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "BetterDualSubCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "BetterDualSubCore", targets: ["BetterDualSubCore"])],
    targets: [
        // Everything in Core is built here and, through the Xcode project's synchronized folder, into the app.
        .target(name: "BetterDualSubCore", path: "BetterDualSub/Core", swiftSettings: appSettings),
        .testTarget(name: "BetterDualSubCoreTests", dependencies: ["BetterDualSubCore"], path: "Tests",
                    swiftSettings: features)
    ]
)
