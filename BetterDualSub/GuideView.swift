import SwiftUI

struct GuideView: View {
    @EnvironmentObject private var manager: SubtitleManager
    @AppStorage(OverlayController.visibleKey) private var showWindow = true

    private var hasSubtitles: Bool { !manager.trackNames.isEmpty }

    private func go(_ page: String) {
        NotificationCenter.default.post(name: .navigateToControlCenter, object: nil, userInfo: ["page": page])
    }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                Text("BetterDualSub")
                    .font(.largeTitle.weight(.semibold))
                Text("guide.description")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("guide.step1.movie") { go("movie") }
                        .buttonStyle(.glassProminent)
                    Button("guide.step1.file") { go("localFile") }
                        .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))

            SettingsCard(titleKey: "guide.steps.title") {
                step(1, "film", "guide.step1.title", "guide.step1.body", complete: hasSubtitles) {
                    Button("nav.localPackage") { go("localPackage") }
                }
                Divider()
                step(2, "play.rectangle.on.rectangle", "guide.step2.title", "guide.step2.body", complete: manager.syncedAppName != nil) {
                    if let name = manager.syncedAppName {
                        Label(name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("nav.general") { go("general") }
                    }
                }
                Divider()
                step(3, "slider.horizontal.3", "guide.step3.title", "guide.step3.body", complete: false) {
                    Button("guide.step3.appearance") { go("appearance") }
                    Button("guide.step3.shortcuts") { go("shortcuts") }
                }
            }

            SettingsCard {
                SettingsRow(symbol: hasSubtitles ? "checkmark.circle.fill" : "circle.dashed",
                            tint: hasSubtitles ? .green : .secondary,
                            titleKey: hasSubtitles ? "common.loaded.title" : "guide.status.empty") { EmptyView() }
                if hasSubtitles {
                    Text(AppLocalization.format("common.currentSubtitles", manager.loadedTitle))
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Divider()
                SyncStatusDetail()
                Divider()
                SettingsRow(symbol: "macwindow", tint: .blue, titleKey: "appearance.window.show", subtitleKey: "appearance.window.help") {
                    Toggle("appearance.window.show", isOn: $showWindow).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(titleKey: "guide.tips.title") {
                tip("menubar.rectangle", "guide.tip.menuBar")
                tip("keyboard", "guide.tip.shortcuts")
                tip("rectangle.on.rectangle", "guide.tip.overlay")
                tip("hand.raised", "guide.tip.privacy")
            }
        }
        .onChange(of: showWindow) { _, _ in NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil) }
    }

    private func step<Actions: View>(_ number: Int, _ symbol: String, _ title: LocalizedStringKey,
                                     _ body: LocalizedStringKey, complete: Bool,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: complete ? "checkmark.circle.fill" : symbol)
                .font(.title3)
                .foregroundStyle(complete ? Color.green : Color.accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) { actions() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
    }

    private func tip(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(key).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
