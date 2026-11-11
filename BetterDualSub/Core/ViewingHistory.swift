import Foundation
import Observation

/// The recent sessions as the interface shows them, over the store on disk: serial writes, a saving delay so a burst of
/// changes (dragging a delay) is written once, and the last error for the interface to report.
@MainActor @Observable
final class ViewingHistory {
    private(set) var sessions: [ViewingSession] = []
    private(set) var error: String?
    @ObservationIgnored private let store: ViewingSessionStore
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    init(store: ViewingSessionStore, saveDelay: Duration = .milliseconds(400)) {
        self.store = store
        self.saveDelay = saveDelay
    }

    func load() async {
        do { sessions = try await store.load() } catch { fail(error) }
    }

    func fail(_ error: Error) { self.error = error.localizedDescription }

    /// Writes `session` after the previous write.
    func record(_ session: ViewingSession) {
        enqueue { [store] in try await store.record(session) }
    }

    /// Writes what `snapshot` returns once nothing has asked again for the saving delay; the latest request wins.
    func scheduleSave(_ snapshot: @escaping @MainActor () -> ViewingSession?) {
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self, let session = snapshot() else { return }
            self.record(session)
        }
    }

    func cancelScheduledSave() { saveTask?.cancel() }

    /// Removes one session, or all for a nil `id`, and then tells `onRemoved` which ids went.
    func remove(id: String?, onRemoved: @escaping @MainActor ([String]) -> Void = { _ in }) {
        saveTask?.cancel()
        let removed = id.map { [$0] } ?? sessions.map(\.id)
        enqueue({ [store] in try await store.remove(id: id) }, then: { onRemoved(removed) })
    }

    /// Writes `pending` (the current session, if any) and waits for every write to finish, as the app quits.
    func flush(pending: ViewingSession?) async {
        saveTask?.cancel()
        if let pending { record(pending) }
        await writeTask?.value
    }

    private func enqueue(_ write: @escaping @Sendable () async throws -> [ViewingSession], then: @escaping @MainActor () -> Void = {}) {
        let previous = writeTask
        writeTask = Task { [weak self] in
            await previous?.value
            do {
                let updated = try await write()
                self?.sessions = updated
                self?.error = nil
                then()
            } catch { self?.fail(error) }
        }
    }

    /// The subtitles of a stored session, decoded off the main thread; a session whose tracks do not match its names
    /// is reported as damaged.
    static func documents(of session: ViewingSession) async throws -> (SubtitleDocument, SubtitleDocument?) {
        try await SubtitleBackgroundWork.run {
            let first = try SubtitleDocument(text: session.primarySRT)
            let second = try session.secondarySRT.map { try SubtitleDocument(text: $0) }
            guard session.names.count == (second == nil ? 1 : 2) else { throw SubtitleError.message("error.history.invalid") }
            return (first, second)
        }
    }
}
