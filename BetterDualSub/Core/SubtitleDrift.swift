import Foundation

/// Drift correction: maps subtitle-file time to video time as `video = file × scale + delay`. Subtitles normally run
/// 1:1 with the video (scale 1). A file made for another frame rate (23.976 → 25 fps is ×1.0427) drifts further off
/// the longer the video plays; fitting two lines the user heard gives the scale that removes it. This is about the
/// file, not the player: playback speed is followed separately and is not part of this.
nonisolated enum SubtitleDrift {
    /// A line at `fileMs` in the subtitle file that is heard at `videoMs` in the video.
    struct Point: Equatable, Sendable {
        let fileMs: Int
        let videoMs: Int
    }

    enum Fit: Equatable, Sendable {
        /// The points are too close together to measure drift.
        case tooClose
        /// The points imply a scale no real frame-rate difference produces, most likely a wrongly picked line.
        case implausible(scale: Double)
        case fitted(scale: Double, offsetMs: Int)
    }

    static let scaleRange: ClosedRange<Double> = 0.9...1.1
    static let minimumSpanMs = 30_000

    static func fileTime(atVideo videoMs: Int, offsetMs: Int, scale: Double) -> Int {
        Int((Double(videoMs - offsetMs) / scale).rounded())
    }

    static func videoTime(ofFile fileMs: Int, offsetMs: Int, scale: Double) -> Int {
        Int((Double(fileMs) * scale).rounded()) + offsetMs
    }

    /// The delay that puts `point` on screen at its video time while keeping `scale`.
    static func offset(for point: Point, scale: Double) -> Int {
        point.videoMs - Int((Double(point.fileMs) * scale).rounded())
    }

    /// The scale and delay that put both points on screen at their video times.
    static func fit(_ a: Point, _ b: Point) -> Fit {
        guard abs(b.fileMs - a.fileMs) >= minimumSpanMs else { return .tooClose }
        let scale = Double(b.videoMs - a.videoMs) / Double(b.fileMs - a.fileMs)
        guard scaleRange.contains(scale) else { return .implausible(scale: scale) }
        // Exactly 1 when the drift over the span is under a frame, so a plain delay stays a plain delay.
        let drift = abs(scale - 1) * Double(abs(b.fileMs - a.fileMs))
        let fitted = drift < 40 ? 1 : scale
        return .fitted(scale: fitted, offsetMs: offset(for: a, scale: fitted))
    }

    /// A stored scale, or 1 when it is not one this correction could have produced.
    static func valid(_ scale: Double) -> Double { scale.isFinite && scaleRange.contains(scale) ? scale : 1 }
}
