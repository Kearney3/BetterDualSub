import SwiftUI

struct RecentWatchingCard: View {
    var limit: Int? = nil
    @EnvironmentObject private var manager: SubtitleManager
    @State private var confirmingClear = false
    @State private var removingID: String?
    private var sessions: [ViewingSession] { Array(manager.recentSessions.prefix(limit ?? manager.recentSessions.count)) }

    var body: some View {
        if !manager.recentSessions.isEmpty || manager.historyError != nil {
            SettingsCard(titleKey: "recent.title") {
                SettingsHint(key: "recent.help")
                ForEach(sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: session.title).lineLimit(1)
                            Text(verbatim: session.names.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(session.openedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("recent.open") { manager.restoreSession(session) }
                        Button { removingID = session.id } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("recent.remove")
                            .accessibilityLabel("recent.remove")
                    }
                    if session.id != sessions.last?.id { Divider() }
                }
                if let error = manager.historyError { StatusLine(text: error, isError: true) }
                HStack {
                    if limit != nil { Button("recent.all") { showControlCenterPage("recent") } }
                    Spacer()
                    Button("recent.clear", role: .destructive) { confirmingClear = true }
                }.controlSize(.small)
            }
            .confirmationDialog("recent.clear.confirm", isPresented: $confirmingClear) {
                Button("recent.clear", role: .destructive) { manager.removeSession(id: nil) }
            }
            .confirmationDialog("recent.remove.confirm", isPresented: Binding(get: { removingID != nil }, set: { if !$0 { removingID = nil } })) {
                Button("recent.remove", role: .destructive) {
                    if let removingID { manager.removeSession(id: removingID) }
                    removingID = nil
                }
            }
        }
    }
}
