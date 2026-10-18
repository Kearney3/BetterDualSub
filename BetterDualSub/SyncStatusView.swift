import SwiftUI

extension SyncStatus {
    var tint: Color {
        switch self {
        case .manual: .blue
        case .following: .green
        case .waiting: .orange
        case .disconnected: .red
        }
    }

    var symbol: String {
        switch self {
        case .manual: "hand.point.up.left"
        case .following(_, let playing): playing ? "play.circle.fill" : "pause.circle.fill"
        case .waiting: "hourglass"
        case .disconnected: "exclamationmark.triangle.fill"
        }
    }
}

/// Coloured dot and one-line status, for the control bar over the subtitles.
struct SyncStatusIndicator: View {
    let status: SyncStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.tint).frame(width: 7, height: 7)
            Text(verbatim: status.title).lineLimit(1)
        }
        .help(status.help ?? status.title)
        .accessibilityElement(children: .combine)
    }
}

/// Status with its explanation and the fix that applies, for the control center.
struct SyncStatusDetail: View {
    @EnvironmentObject private var manager: SubtitleManager

    var body: some View {
        let status = manager.syncStatus
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: status.symbol, tint: status.tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: status.title)
                    if status.isFollowing {
                        Text(verbatim: manager.debugTimeStr).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let help = status.help {
                    Text(verbatim: help).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                action(for: status).controlSize(.small).padding(.top, 2)
                if !manager.trackNames.isEmpty {
                    Text(LocalizedStringKey(manager.subtitleHealthKey)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("align.open") { showControlCenterPage("align") }
                        Button("nav.load") { showControlCenterPage("load") }
                    }.controlSize(.small)
                }
                Button("diagnostics.export") { manager.exportDiagnostics() }.controlSize(.small)
                Text("diagnostics.privacy").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func action(for status: SyncStatus) -> some View {
        switch status {
        case .manual:
            Button("sync.action.auto") { manager.setSyncMode(.auto) }
        case .waiting(let app?):
            Button(AppLocalization.format("sync.action.follow", app.name)) { manager.follow(app) }
        case .disconnected:
            Button("sync.action.reconnect") { manager.reconnect() }
        case .following, .waiting(nil):
            EmptyView()
        }
    }
}
