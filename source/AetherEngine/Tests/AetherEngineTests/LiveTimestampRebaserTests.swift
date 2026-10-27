import XCTest
@testable import AetherEngine

/// The pattern seen with an Xtream restream: after a reconnect the origin resends its last ~20 s byte for byte,
/// with its clock restarted from 1.46 s.
final class LiveTimestampRebaserTests: XCTestCase {
    private let tb = 1.0 / 90_000

    private func payload(_ n: Int) -> [UInt8] { Array("frame-\(n)".utf8) + [UInt8](repeating: UInt8(n % 251), count: 2_000) }

    private func feed(_ r: inout LiveTimestampRebaser, _ n: Int, rawSeconds: Double) -> (Int64, Bool) {
        let bytes = payload(n)
        let dts = Int64((rawSeconds / tb).rounded())
        return bytes.withUnsafeBytes { buf in
            let out = r.rebase(stream: .video, dts: dts, pts: dts, timeBaseSeconds: tb, payload: buf)
            return (out.dts, out.shifted)
        }
    }

    func testReplayWithResetClockGetsItsOriginalTimestampsBack() {
        var r = LiveTimestampRebaser()
        // First connection: frames 0...3749 at 25 fps from 1.46 s (150 s).
        var original: [Int: Int64] = [:]
        for n in 0..<3750 {
            let (dts, shifted) = feed(&r, n, rawSeconds: 1.46 + Double(n) / 25)
            XCTAssertFalse(shifted)
            original[n] = dts
        }
        // Second connection: the last 20 s again (frames 3250...), clock from 1.46 s, then new frames.
        var shifts = 0
        for k in 0..<1000 {
            let n = 3250 + k
            let (dts, shifted) = feed(&r, n, rawSeconds: 1.46 + Double(k) / 25)
            if shifted { shifts += 1 }
            if let o = original[n] { XCTAssertEqual(dts, o, "frame \(n) must get its original time back") }
            else { XCTAssertGreaterThan(dts, original[3749]!, "new frames continue after the old ones") }
        }
        XCTAssertEqual(shifts, 1)
    }

    func testEncoderRestartWithNewPicturesKeepsItsOwnClock() {
        var r = LiveTimestampRebaser()
        for n in 0..<500 { _ = feed(&r, n, rawSeconds: 1.46 + Double(n) / 25) }
        // New pictures (never seen) with a reset clock: nothing to align to.
        let (dts, shifted) = feed(&r, 99_999, rawSeconds: 1.46)
        XCTAssertFalse(shifted)
        XCTAssertEqual(dts, Int64((1.46 / tb).rounded()))
    }
}

extension LiveTimestampRebaserTests {
    func testRepeatedStillPictureNeverShiftsTheClock() {
        var r = LiveTimestampRebaser()
        // The same picture at 10 s and at 20 s (a still): later seeing it again after a jump back proves nothing.
        _ = feed(&r, 7, rawSeconds: 10)
        _ = feed(&r, 1, rawSeconds: 15)
        _ = feed(&r, 7, rawSeconds: 20)
        let (_, shifted) = feed(&r, 7, rawSeconds: 2)
        XCTAssertFalse(shifted)
    }
}
