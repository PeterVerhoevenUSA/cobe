import CryptoKit
import Foundation

/// Some live origins resend the last stretch of media after every reconnect AND restart their
/// clock from zero (seen with an Xtream restream: the second connection began with the previous
/// connection's last ~20 s, byte for byte, timestamped from 1.46 s again). `LivePacketReplayGuard`
/// proves a replay by matching timestamps and payloads, so a replay with a reset clock reached the
/// screen a second time.
///
/// This rebaser puts such a source back on its own timeline before the guard looks at it: when a
/// packet's timestamp jumps back and its payload is one already received, the source's clock is
/// shifted so that packet gets its original timestamps back. From then on the guard sees an exact
/// replay (same timestamps, same payload) and drops it, and the new media continues seamlessly.
/// Without a payload match nothing changes: a real encoder restart keeps its own timestamps.
///
/// Pump-thread-only. Stores digests and times, never payloads; history is bounded.
struct LiveTimestampRebaser {
    enum Stream: Hashable { case video, audio }

    private struct Key: Hashable {
        let stream: Stream
        let digest: SHA256.Digest
    }

    /// Seconds added to every source timestamp (0 until a replay with a reset clock is seen).
    private(set) var offsetSeconds = 0.0
    private var lastSeconds: [Stream: Double] = [:]
    private var known: [Key: Double] = [:]
    private var order: [(key: Key, seconds: Double)] = []
    private var orderStart = 0
    private var ambiguous: Set<Key> = []

    private static let historySeconds = 60.0
    private static let maximumEntries = 12_000
    /// A jump back smaller than this is ordinary reordering, not a reconnect.
    private static let backwardJumpSeconds = 1.0
    private static let minimumPayloadBytes = 1_024

    var isShifted: Bool { offsetSeconds != 0 }
    /// Tests only: compare with the engine as it was.
    nonisolated(unsafe) static var isEnabled = true
    nonisolated(unsafe) static var debug = false

    mutating func reset() {
        offsetSeconds = 0
        lastSeconds = [:]
        known = [:]
        order = []
        orderStart = 0
        ambiguous = []
    }

    /// Returns the timestamps the packet should carry (source time base), and whether this packet
    /// just established a new shift.
    mutating func rebase(stream: Stream, dts: Int64, pts: Int64, timeBaseSeconds: Double,
                         payload: UnsafeRawBufferPointer) -> (dts: Int64, pts: Int64, shifted: Bool) {
        guard Self.isEnabled, timeBaseSeconds > 0, dts != Int64.min else { return (dts, pts, false) }
        let rawSeconds = Double(dts) * timeBaseSeconds
        var seconds = rawSeconds + offsetSeconds
        var shifted = false
        // Only pictures prove a reset clock: audio frames (silence above all) repeat byte for byte in normal
        // programmes. Small or repeated pictures prove nothing either.
        let usable = stream == .video && payload.count >= Self.minimumPayloadBytes
        let key = usable ? Key(stream: stream, digest: SHA256.hash(data: payload)) : nil
        if Self.debug, let last = lastSeconds[stream], last - seconds > Self.backwardJumpSeconds {
            EngineLog.emit("[LiveRebase] debug: \(stream) jumped back \(String(format: "%.2f", last - seconds)) s, size \(payload.count), usable \(usable), known \(key.map { known[$0] != nil } ?? false)", category: .session)
        }
        if let key, let last = lastSeconds[stream], last - seconds > Self.backwardJumpSeconds,
           !ambiguous.contains(key), let original = known[key], abs(original - seconds) > Self.backwardJumpSeconds {
            // A picture received before, now with an earlier clock: the clock was reset.
            offsetSeconds = original - rawSeconds
            seconds = original
            shifted = true
        }
        let shift = Int64((offsetSeconds / timeBaseSeconds).rounded())
        let newDts = dts + shift
        let newPts = pts == Int64.min ? pts : pts + shift
        if let key {
            if let earlier = known[key] {
                // The same picture twice in one timeline (a still, a test card): never evidence.
                if abs(earlier - seconds) > Self.backwardJumpSeconds, !shifted { ambiguous.insert(key) }
            } else {
                known[key] = seconds
                order.append((key, seconds))
            }
        }
        lastSeconds[stream] = Swift.max(lastSeconds[stream] ?? seconds, seconds)
        prune(newest: seconds)
        return (newDts, newPts, shifted)
    }

    private mutating func prune(newest: Double) {
        let cutoff = newest - Self.historySeconds
        while orderStart < order.count,
              order[orderStart].seconds < cutoff || order.count - orderStart > Self.maximumEntries {
            let old = order[orderStart]
            if known[old.key] == old.seconds { known.removeValue(forKey: old.key); ambiguous.remove(old.key) }
            orderStart += 1
        }
        if orderStart > 2_048 {
            order.removeFirst(orderStart)
            orderStart = 0
        }
    }
}
