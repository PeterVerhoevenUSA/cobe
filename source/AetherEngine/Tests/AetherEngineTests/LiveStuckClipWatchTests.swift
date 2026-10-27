import XCTest
@testable import AetherEngine

final class LiveStuckClipWatchTests: XCTestCase {
    func testSameRestartPointTwiceIsStuck() {
        var watch = LiveStuckClipWatch()
        XCTAssertFalse(watch.restarted(atSeconds: 100.1))
        XCTAssertTrue(watch.restarted(atSeconds: 100.1))
        XCTAssertFalse(watch.restarted(atSeconds: 100.1), "reported once")
    }

    func testRestartsAtNewPointsAreNotStuck() {
        var watch = LiveStuckClipWatch()
        XCTAssertFalse(watch.restarted(atSeconds: 100.1))
        XCTAssertFalse(watch.restarted(atSeconds: 120.2))
        XCTAssertFalse(watch.restarted(atSeconds: 140.3))
    }
}
