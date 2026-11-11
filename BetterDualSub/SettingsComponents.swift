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
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    Text(subtitleKey).font(.subheadline).foregroundStyle(.secondary)
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
        Text(key).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A card's heading with a control (a reset button, say) at its trailing edge.
struct SettingsCardHeader<Trailing: View>: View {
    let titleKey: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(titleKey).font(.headline)
            Spacer(minLength: 12)
            trailing()
        }
    }
}

/// A plain form row: the label on the left and its control at the trailing edge, so the controls of a card line up.
struct SettingsField<Control: View>: View {
    let title: Text
    var subtitleKey: LocalizedStringKey?
    @ViewBuilder var control: () -> Control

    init(_ titleKey: LocalizedStringKey, subtitleKey: LocalizedStringKey? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: Text(titleKey), subtitleKey: subtitleKey, control: control)
    }

    init(title: Text, subtitleKey: LocalizedStringKey? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.subtitleKey = subtitleKey
        self.control = control
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title
                if let subtitleKey {
                    Text(subtitleKey).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

/// A form row with a slider and its current value, both in fixed columns so stacked sliders line up.
struct SettingsSlider: View {
    let titleKey: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// The value as shown after the slider ("32 pt").
    let valueText: String

    var body: some View {
        SettingsField(titleKey) {
            Slider(value: $value, in: range, step: step)
                .frame(minWidth: 120, idealWidth: 260, maxWidth: 260)
                .accessibilityLabel(Text(titleKey))
                .accessibilityValue(Text(verbatim: valueText))
            Text(verbatim: valueText)
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
    }
}

/// A number typed in milliseconds, with its unit.
struct MillisecondsField: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 6) {
            TextField("0", value: $value, format: .number)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 90)
            Text(verbatim: "ms").foregroundStyle(.secondary)
        }
    }
}

/// Dashed placeholder inviting a drop, lit up while something is dragged over it.
struct DropZoneLabel: View {
    let symbol: String
    let textKey: LocalizedStringKey
    var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(textKey).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 84)
        .dropZoneBackground(targeted: targeted)
    }
}

extension View {
    /// The dashed outline of a place that takes dropped files.
    func dropZoneBackground(targeted: Bool, cornerRadius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(.quaternary.opacity(0.35)), in: shape)
            .overlay {
                shape.strokeBorder(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary),
                                   style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [6, 4]))
            }
            .animation(.easeOut(duration: 0.12), value: targeted)
    }

    /// Accent outline around a whole card while files are dragged over it.
    func dropHighlight(_ targeted: Bool, cornerRadius: CGFloat = 16) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(targeted ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: targeted)
                .allowsHitTesting(false)
        }
    }
}

/// A running task's status with a way to stop it, for the loading pages.
struct BusyStatusRow: View {
    let text: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(verbatim: text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("common.cancel", action: cancel).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// Switches the open control center to `page`, a page name it understands (see `ControlCenterPage.resolve`).
func showControlCenterPage(_ page: String) {
    NotificationCenter.default.post(name: .navigateToControlCenter, object: nil, userInfo: ["page": page])
}

/// Delay and linking of the loaded tracks, on Now Playing.
struct SubtitleTimingCard: View {
    @Environment(SubtitleManager.self) private var manager
    @AppStorage(SubtitleManager.trackSnapToleranceKey) private var snapTolerance = SubtitleManager.defaultTrackSnapToleranceMs

    private var hasSecondTrack: Bool { manager.trackNames.count > 1 }

    var body: some View {
        SettingsCard(titleKey: "timing.title") {
            if manager.restoredTiming {
                Label("timing.restored", systemImage: "clock.arrow.circlepath")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                delayRow(hasSecondTrack && manager.linkSecondaryDelay ? "timing.both" : "nowPlaying.track.primary",
                         value: Bindable(manager).timeOffsetMs, track: .primary)
                if hasSecondTrack && !manager.linkSecondaryDelay {
                    delayRow("nowPlaying.track.secondary", value: Bindable(manager).secondaryOffsetMs, track: .secondary)
                }
            }
            if hasSecondTrack {
                Toggle("delay.link", isOn: Binding(get: { manager.linkSecondaryDelay }, set: { manager.setLink($0) }))
                Divider()
                snapRow
            }
            Divider()
            HStack(spacing: 12) {
                SettingsHint(key: "timing.help")
                Spacer(minLength: 12)
                Button("align.open") { showControlCenterPage("align") }
            }
        }
    }

    /// How far apart a Track 2 line may start or end from a Track 1 line and still change together with it.
    private var snapRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SnapToleranceSlider(tolerance: $snapTolerance)
            HStack(alignment: .top, spacing: 12) {
                SettingsHint(key: "timing.snap.help")
                Spacer(minLength: 12)
                Button("timing.snap.default") { snapTolerance = SubtitleManager.defaultTrackSnapToleranceMs }
                    .controlSize(.small)
                    .disabled(snapTolerance == SubtitleManager.defaultTrackSnapToleranceMs)
            }
        }
    }

    /// Label, earlier / later steps around the typed value, and a reset; the steps follow the shortcut step.
    private func delayRow(_ title: LocalizedStringKey, value: Binding<Int>, track: Track) -> some View {
        let step = SubtitleDelayStep.milliseconds
        return GridRow {
            Text(title).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button { manager.adjustDelay(track: track, delta: -step) } label: { Image(systemName: "minus") }
                    .help(AppLocalization.format("bar.delay.earlier", "\(step) ms"))
                    .accessibilityLabel(Text(verbatim: AppLocalization.format("bar.delay.earlier", "\(step) ms")))
                TextField("0", value: value, format: .number)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit()
                    .frame(width: 90)
                Text(verbatim: "ms").foregroundStyle(.secondary)
                Button { manager.adjustDelay(track: track, delta: step) } label: { Image(systemName: "plus") }
                    .help(AppLocalization.format("bar.delay.later", "\(step) ms"))
                    .accessibilityLabel(Text(verbatim: AppLocalization.format("bar.delay.later", "\(step) ms")))
            }
            Button("timing.reset") { manager.adjustDelay(track: track, delta: Int.min) }
                .disabled(value.wrappedValue == 0)
        }
    }
}

/// How far apart two tracks' lines may be and still change together; 0 turns lining up off.
struct SnapToleranceSlider: View {
    @Binding var tolerance: Int

    var body: some View {
        SettingsSlider(titleKey: "timing.snap",
                       value: Binding(get: { Double(tolerance) }, set: { tolerance = Int($0) }),
                       range: Double(SubtitleManager.trackSnapTolerances.lowerBound)...Double(SubtitleManager.trackSnapTolerances.upperBound),
                       step: 100,
                       valueText: tolerance == 0 ? AppLocalization.string("timing.snap.off") : "\(tolerance) ms")
    }
}
