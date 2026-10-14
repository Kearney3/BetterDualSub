import XCTest
@testable import BetterDualSubCore

final class AppVersionTests: XCTestCase {
    func testParsesTagsAndComparesNumerically() throws {
        let tag = try XCTUnwrap(AppVersion("v1.10.0"))
        XCTAssertEqual(tag.description, "1.10.0")
        XCTAssertGreaterThan(tag, try XCTUnwrap(AppVersion("1.9.3")))
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.0.0")), try XCTUnwrap(AppVersion("1.0.1")))
        XCTAssertEqual(AppVersion("2.0.0-beta.1"), AppVersion("2.0.0"))
    }

    func testRejectsNonVersions() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("1.-2"))
    }
}
