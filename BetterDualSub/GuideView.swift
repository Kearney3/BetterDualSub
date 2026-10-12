import SwiftUI

struct GuideView: View {
    @EnvironmentObject private var manager: SubtitleManager
    @AppStorage(OverlayController.visibleKey) private var showWindow = true

    private func go(_ page: String) {
        NotificationCenter.default.post(name: .navigateToControlCenter, object: nil, userInfo: ["page": page])
    }

    var body: some View {
        SettingsPage(descriptionKey: "guide.description") {
            SettingsCard {
                SettingsRow(symbol: manager.trackNames.isEmpty ? "circle.dashed" : "checkmark.circle.fill",
                            tint: manager.trackNames.isEmpty ? .secondary : .green,
                            titleKey: manager.trackNames.isEmpty ? "guide.status.empty" : "common.loaded.title") { EmptyView() }
                if !manager.trackNames.isEmpty {
                    Text(AppLocalization.format("common.currentSubtitles", manager.loadedTitle)).font(.caption).foregroundStyle(.secondary)
                }
            }

            SettingsCard {
                SettingsRow(symbol: "macwindow", tint: .blue, titleKey: "appearance.window.show", subtitleKey: "appearance.window.help") {
                    Toggle("appearance.window.show", isOn: $showWindow).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsCard(titleKey: "guide.steps.title") {
                step(1, "film", .blue, "guide.step1.title", "guide.step1.body", "guide.step1.movie", "movie", "guide.step1.file", "localFile")
                Divider()
                step(2, "tv", .indigo, "guide.step2.title", "guide.step2.body", nil, nil, nil, nil)
                Divider()
                step(3, "textformat", .pink, "guide.step3.title", "guide.step3.body", "guide.step3.appearance", "appearance", "guide.step3.shortcuts", "shortcuts")
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

    private func step(_ number: Int, _ symbol: String, _ tint: Color, _ title: LocalizedStringKey, _ body: LocalizedStringKey,
                      _ firstLabel: LocalizedStringKey?, _ firstPage: String?,
                      _ secondLabel: LocalizedStringKey?, _ secondPage: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let firstLabel, let firstPage { Button(firstLabel) { go(firstPage) } }
                    if let secondLabel, let secondPage { Button(secondLabel) { go(secondPage) } }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
            Text("\(number)").font(.title3.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    private func tip(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(key).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
