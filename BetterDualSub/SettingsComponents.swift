import SwiftUI

/// Scrollable page with a large title, optional description and card content.
struct SettingsPage<Content: View>: View {
    var descriptionKey: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let descriptionKey {
                    Text(descriptionKey)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
    }
}

/// Rounded group that stacks rows separated by dividers.
struct SettingsCard<Content: View>: View {
    var titleKey: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let titleKey {
                Text(titleKey).font(.headline)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardBackground()
    }
}

extension View {
    func settingsCardBackground() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
}

struct IconTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Icon tile + title/subtitle on the left, a control on the right.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    let titleKey: LocalizedStringKey
    var subtitleKey: LocalizedStringKey?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey)
                if let subtitleKey {
                    Text(subtitleKey).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

struct SettingsHint: View {
    let key: LocalizedStringKey
    var body: some View {
        Text(key).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Inline status line used by the long-running download / extract pages.
struct StatusLine: View {
    let text: String
    var isError = false
    var body: some View {
        Label {
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
        }
        .font(.callout)
        .foregroundStyle(isError ? Color.red : Color.secondary)
    }
}

/// "Currently loaded" summary shown on pages that load subtitles.
struct LoadedSubtitleCard<Extra: View>: View {
    @EnvironmentObject private var manager: SubtitleManager
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        if !manager.trackNames.isEmpty {
            SettingsCard {
                SettingsRow(symbol: "checkmark.circle.fill", tint: .green, titleKey: "common.loaded.title") { EmptyView() }
                Text(AppLocalization.format("common.currentSubtitles", manager.loadedTitle)).font(.subheadline.weight(.medium))
                Text(manager.trackNames.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack(spacing: 10) {
                    Text("delay.field.primary")
                    TextField("0", value: $manager.timeOffsetMs, format: .number).frame(width: 80)
                    Text("delay.field.secondary")
                    TextField("0", value: $manager.secondaryOffsetMs, format: .number).frame(width: 80)
                        .disabled(manager.linkSecondaryDelay)
                }.textFieldStyle(.roundedBorder)
                Toggle("delay.link", isOn: Binding(get: { manager.linkSecondaryDelay }, set: { manager.setLink($0) }))
                HStack {
                    Button("download.delay.resetPrimary") { manager.adjustDelay(track: "primary", delta: Int.min) }
                    Button("download.delay.resetSecondary") { manager.adjustDelay(track: "secondary", delta: Int.min) }
                }
                SettingsHint(key: "download.delay.help")
                extra()
            }
        }
    }
}
