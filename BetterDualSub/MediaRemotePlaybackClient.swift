import Foundation
import MediaRemoteAdapter

@MainActor
final class MediaRemotePlaybackClient: PlaybackClient {
    var onReport: ((NowPlayingReport?) -> Void)?
    var onDisconnect: (() -> Void)?
    var onDecodeFailure: (() -> Void)?
    private var controller: MediaController?
    private var generation = UUID()

    func start() {
        let token = generation
        let controller = MediaController()
        self.controller = controller
        controller.onTrackInfoReceived = { [weak self] track in
            let report = Self.report(track)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onReport?(report)
            }
        }
        controller.onListenerTerminated = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onDisconnect?()
            }
        }
        controller.onDecodingError = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onDecodeFailure?()
            }
        }
        controller.startListening()
    }

    func stop() {
        generation = UUID()
        controller?.onTrackInfoReceived = nil
        controller?.onListenerTerminated = nil
        controller?.onDecodingError = nil
        controller?.stopListening()
        controller = nil
    }

    func requestReport(_ completion: @escaping @MainActor (NowPlayingReport?) -> Void) {
        let token = generation
        controller?.getTrackInfo { [weak self] track in
            let report = Self.report(track)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                completion(report)
            }
        }
    }

    func togglePlayPause() { controller?.togglePlayPause() }
    func seek(seconds: Double) { controller?.setTime(seconds: seconds) }

    private nonisolated static func report(_ track: TrackInfo?) -> NowPlayingReport? {
        track.map {
            NowPlayingReport(bundleID: $0.payload.bundleIdentifier, appName: $0.payload.applicationName,
                             isPlaying: $0.payload.isPlaying, playbackRate: $0.payload.playbackRate,
                             elapsedMicros: $0.payload.elapsedTimeMicros, timestampEpochMicros: $0.payload.timestampEpochMicros,
                             durationMicros: $0.payload.durationMicros)
        }
    }
}
