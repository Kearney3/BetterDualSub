import XCTest
@testable import BetterDualSubCore

final class ReleaseLookupTests: XCTestCase {
    private func outcome(_ status: Int, _ body: String = "", headers: [String: String] = [:]) -> ReleaseLookup.Outcome {
        ReleaseLookup.outcome(status: status, data: Data(body.utf8)) { headers[$0] }
    }

    func testReadsTheLatestReleaseAndItsETag() throws {
        let body = #"{"tag_name": "v1.6.0", "html_url": "https://github.com/Kearney3/BetterDualSub/releases/tag/v1.6.0", "draft": false}"#
        let release = ReleaseLookup.Release(version: try XCTUnwrap(AppVersion("1.6.0")),
                                            page: try XCTUnwrap(URL(string: "https://github.com/Kearney3/BetterDualSub/releases/tag/v1.6.0")))
        XCTAssertEqual(outcome(200, body, headers: ["ETag": #"W/"abc""#]), .release(release, etag: #"W/"abc""#))
        XCTAssertEqual(outcome(200, body), .release(release, etag: nil))
    }

    func testRefusesAnswersThatAreNotARelease() {
        XCTAssertEqual(outcome(200, "<html>"), .unreadable)
        XCTAssertEqual(outcome(200, #"{"tag_name": "nightly", "html_url": "https://example.com/"}"#), .unreadable)
        XCTAssertEqual(outcome(200, #"{"tag_name": "v2.0.0", "html_url": "file:///Applications"}"#), .unreadable)
        XCTAssertEqual(outcome(200, #"{"tag_name": "v2.0.0"}"#), .unreadable)
    }

    func testUnchangedAndFailedAnswers() {
        XCTAssertEqual(outcome(304), .unchanged)
        XCTAssertEqual(outcome(404), .failed(status: 404))
        XCTAssertEqual(outcome(500), .failed(status: 500))
        // 403 without an exhausted limit is some other refusal.
        XCTAssertEqual(outcome(403, headers: ["X-RateLimit-Remaining": "12"]), .failed(status: 403))
    }

    func testRateLimitSaysWhenToTryAgain() {
        XCTAssertEqual(outcome(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"]),
                       .rateLimited(retryAt: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(outcome(429), .rateLimited(retryAt: nil))
        guard case .rateLimited(let retryAt?) = outcome(429, headers: ["Retry-After": "120"]) else {
            return XCTFail("Expected a time to retry at")
        }
        XCTAssertEqual(retryAt.timeIntervalSinceNow, 120, accuracy: 5)
    }

    func testRequestAsksOnlyWhetherTheAnswerChanged() {
        let first = ReleaseLookup.request(etag: nil)
        XCTAssertEqual(first.url, ReleaseLookup.latestURL)
        XCTAssertNil(first.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(first.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(ReleaseLookup.request(etag: "").value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(ReleaseLookup.request(etag: #""abc""#).value(forHTTPHeaderField: "If-None-Match"), #""abc""#)
    }

    func testAutomaticCheckIsDueOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), day: TimeInterval = 86_400
        XCTAssertTrue(ReleaseLookup.isDue(lastCheck: nil, now: now, interval: day))
        XCTAssertFalse(ReleaseLookup.isDue(lastCheck: now.addingTimeInterval(-3600), now: now, interval: day))
        XCTAssertTrue(ReleaseLookup.isDue(lastCheck: now.addingTimeInterval(-day), now: now, interval: day))
        // A clock set back must not put off checks until it catches up.
        XCTAssertTrue(ReleaseLookup.isDue(lastCheck: now.addingTimeInterval(3 * day), now: now, interval: day))
    }
}
