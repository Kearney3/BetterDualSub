import XCTest
@testable import BetterDualSubCore

final class DualTrackTimingTests: XCTestCase {
    func testLinkedTracksShareDelaysAndAreBounded() {
        var timing = DualTrackTiming(linked: true)
        timing.setDelay(.secondary, ms: 1200)
        XCTAssertEqual(timing.primaryOffsetMs, 1200)
        timing.setDelay(.primary, ms: 5 * DualTrackTiming.delayLimitMs)
        XCTAssertEqual(timing.primaryOffsetMs, DualTrackTiming.delayLimitMs)
        XCTAssertEqual(timing.secondaryOffsetMs, DualTrackTiming.delayLimitMs)
        timing.setDelay(.secondary, ms: -5 * DualTrackTiming.delayLimitMs)
        XCTAssertEqual(timing.primaryOffsetMs, -DualTrackTiming.delayLimitMs)
    }

    func testUnlinkedTracksMoveApartAndRelinkingFollowsTrackOne() {
        var timing = DualTrackTiming(linked: false)
        timing.setDelay(.primary, ms: 500)
        timing.setDelay(.secondary, ms: -300)
        XCTAssertEqual(timing.offsetMs(.primary), 500)
        XCTAssertEqual(timing.offsetMs(.secondary), -300)
        XCTAssertEqual(timing.summary(hasSecondary: true), "+500 ms / -300 ms")
        XCTAssertEqual(timing.summary(hasSecondary: false), "+500 ms")
        timing.setLinked(true)
        XCTAssertEqual(timing.offsetMs(.secondary), 500)
        XCTAssertEqual(timing.summary(hasSecondary: true), "+500 ms")
    }

    func testMappingIsInverseOfItself() {
        var timing = DualTrackTiming(linked: false)
        timing.setDelay(.primary, ms: 2000)
        XCTAssertEqual(timing.fileTimeMs(.primary, atVideo: 10_000), 8000)
        XCTAssertEqual(timing.videoTimeMs(.primary, ofFile: 8000), 10_000)
        XCTAssertEqual(timing.fileTimeMs(.secondary, atVideo: 10_000), 10_000)
    }

    func testAlignKeepsScaleAndRemembersTheLine() {
        var timing = DualTrackTiming(linked: false)
        XCTAssertEqual(timing.align(.primary, toFile: 8000, atVideo: 10_000), 2000)
        XCTAssertEqual(timing.anchor(.primary), .init(fileMs: 8000, videoMs: 10_000))
        XCTAssertNil(timing.anchor(.secondary))
    }

    func testCorrectDriftNeedsAFirstLineAndOnlyUsableFitsChangeAnything() {
        var timing = DualTrackTiming(linked: false)
        XCTAssertNil(timing.correctDrift(.primary, toFile: 100_000, atVideo: 100_000))
        timing.align(.primary, toFile: 60_000, atVideo: 62_000)
        let before = timing
        XCTAssertEqual(timing.correctDrift(.primary, toFile: 70_000, atVideo: 72_000), .tooClose)
        XCTAssertEqual(timing, before)
        guard case .implausible = timing.correctDrift(.primary, toFile: 200_000, atVideo: 400_000) else { return XCTFail("expected implausible") }
        XCTAssertEqual(timing, before)
        // 23.976 fps file at 25 fps, starting 2 s late.
        let scale = 25 / 23.976
        let video = { (file: Int) in Int((Double(file) * scale).rounded()) + 2000 }
        timing = DualTrackTiming(linked: false)
        timing.align(.primary, toFile: 60_000, atVideo: video(60_000))
        guard case .fitted(let fitted, _)? = timing.correctDrift(.primary, toFile: 3_600_000, atVideo: video(3_600_000)) else { return XCTFail("expected a fit") }
        XCTAssertEqual(fitted, scale, accuracy: 0.00001)
        XCTAssertEqual(timing.primaryScale, scale, accuracy: 0.00001)
        XCTAssertEqual(timing.secondaryScale, 1)
        XCTAssertEqual(timing.videoTimeMs(.primary, ofFile: 1_800_000), video(1_800_000), accuracy: 3)
        XCTAssertNil(timing.snapShiftMs, "different corrections are not a constant shift apart")
    }

    func testLinkedDriftCorrectionAndResetApplyToBothTracks() {
        var timing = DualTrackTiming(linked: true)
        timing.align(.secondary, toFile: 60_000, atVideo: 62_000)
        _ = timing.correctDrift(.secondary, toFile: 3_000_000, atVideo: 3_125_000)
        XCTAssertEqual(timing.primaryScale, timing.secondaryScale)
        XCTAssertNotEqual(timing.primaryScale, 1)
        XCTAssertEqual(timing.primaryOffsetMs, timing.secondaryOffsetMs)
        // Reset keeps the line that is on screen where it is.
        let onScreen = timing.fileTimeMs(.primary, atVideo: 1_000_000)
        timing.resetDrift(.primary, atVideo: 1_000_000)
        XCTAssertEqual(timing.primaryScale, 1)
        XCTAssertEqual(timing.secondaryScale, 1)
        XCTAssertEqual(timing.fileTimeMs(.primary, atVideo: 1_000_000), onScreen, accuracy: 1)
        XCTAssertNil(timing.anchor(.primary))
    }

    func testSnapShiftIsTheDelayDifferenceInTrackOneTime() {
        var timing = DualTrackTiming(linked: false)
        timing.setDelay(.primary, ms: 1500)
        timing.setDelay(.secondary, ms: 500)
        XCTAssertEqual(timing.snapShiftMs, 1000)
    }

    func testSavedTimingRoundTripAndLinkedRestore() {
        let saved = SavedTiming(primaryOffsetMs: 1200, secondaryOffsetMs: 800, primaryScale: 1.0427, secondaryScale: 1)
        let unlinked = DualTrackTiming(saved: saved, linked: false)
        XCTAssertEqual(unlinked.saved, saved)
        XCTAssertTrue(unlinked.isAdjusted)
        let linked = DualTrackTiming(saved: saved, linked: true)
        XCTAssertEqual(linked.secondaryOffsetMs, 1200)
        XCTAssertEqual(linked.secondaryScale, 1.0427)
        XCTAssertFalse(DualTrackTiming(saved: SavedTiming(), linked: true).isAdjusted)
        XCTAssertEqual(DualTrackTiming(saved: SavedTiming(primaryOffsetMs: 9 * DualTrackTiming.delayLimitMs), linked: true).primaryOffsetMs,
                       DualTrackTiming.delayLimitMs)
    }

    func testApplyDelaysUnlinksOnlyForAnExtraDelay() {
        var timing = DualTrackTiming(linked: true)
        timing.applyDelays(primary: 300, secondaryExtra: 0, preferredLink: true)
        XCTAssertTrue(timing.linked)
        XCTAssertEqual(timing.secondaryOffsetMs, 300)
        timing.applyDelays(primary: 300, secondaryExtra: 150, preferredLink: true)
        XCTAssertFalse(timing.linked)
        XCTAssertEqual(timing.secondaryOffsetMs, 450)
        timing.applyDelays(primary: 100, secondaryExtra: 0, preferredLink: false)
        XCTAssertFalse(timing.linked)
        XCTAssertEqual(timing.secondaryOffsetMs, 100)
    }

    func testTranslatedSecondaryStartsWhereTrackOneIsAndUndoRestoresTheOldOne() {
        var timing = DualTrackTiming(linked: false)
        timing.setDelay(.primary, ms: 700)
        timing.setDelay(.secondary, ms: -200)
        let snapshot = timing.secondarySnapshot
        timing.matchSecondaryToPrimary()
        XCTAssertEqual(timing.secondaryOffsetMs, 700)
        timing.restore(snapshot)
        XCTAssertEqual(timing.secondaryOffsetMs, -200)
        XCTAssertFalse(timing.linked)
        XCTAssertEqual(timing.primaryOffsetMs, 700)
    }

    func testTrackHelpers() {
        XCTAssertEqual(Track(secondary: true), .secondary)
        XCTAssertEqual(Track.primary.other, .secondary)
        XCTAssertEqual(Track.allCases.map(\.rawValue), ["primary", "secondary"])
    }
}
