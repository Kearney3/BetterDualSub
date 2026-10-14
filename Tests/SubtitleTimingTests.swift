import XCTest
@testable import BetterDualSubCore

final class SubtitleTimingTests: XCTestCase {
    func testFitsFrameRateDriftAndOffset() {
        // A 23.976 fps file played at 25 fps (scale 25 / 23.976), starting 2 s late.
        let scale = 25 / 23.976
        let point = { (file: Int) in SubtitleTiming.Point(fileMs: file, videoMs: Int((Double(file) * scale).rounded()) + 2000) }
        guard case .fitted(let fitted, let offset) = SubtitleTiming.fit(point(60_000), point(3_600_000)) else {
            return XCTFail("expected a fit")
        }
        XCTAssertEqual(fitted, scale, accuracy: 0.00001)
        XCTAssertEqual(offset, 2000, accuracy: 2)
        // Mapping back from video time lands on the file time of the line.
        XCTAssertEqual(SubtitleTiming.fileTime(atVideo: point(1_800_000).videoMs, offsetMs: offset, scale: fitted), 1_800_000, accuracy: 2)
    }

    func testPlainOffsetSnapsToUnitScale() {
        let a = SubtitleTiming.Point(fileMs: 100_000, videoMs: 101_500)
        let b = SubtitleTiming.Point(fileMs: 1_000_000, videoMs: 1_001_520)
        XCTAssertEqual(SubtitleTiming.fit(a, b), .fitted(scale: 1, offsetMs: 1500))
    }

    func testRejectsCloseOrImplausiblePoints() {
        let a = SubtitleTiming.Point(fileMs: 100_000, videoMs: 100_000)
        XCTAssertEqual(SubtitleTiming.fit(a, .init(fileMs: 110_000, videoMs: 110_500)), .tooClose)
        guard case .implausible = SubtitleTiming.fit(a, .init(fileMs: 200_000, videoMs: 300_000)) else {
            return XCTFail("expected an implausible speed")
        }
    }

    func testOffsetKeepsScale() {
        XCTAssertEqual(SubtitleTiming.offset(for: .init(fileMs: 10_000, videoMs: 12_000), scale: 1.5), -3000)
    }
}
