import Foundation
import Testing
@testable import AetherEngine

/// Real recordings of an Xtream restream (not committed: paths come from AETHER_REPLAY_A / AETHER_REPLAY_B).
/// B is the connection made right after A ended; it begins with A's last ~20 s byte for byte, its clock reset.
@Suite("Real reset-clock replay", .serialized, .timeLimit(.minutes(5)))
struct RealResetClockReplayTests {
    private final class Reader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let lock = NSLock()
        private var position = 0
        init(_ bytes: Data) { self.bytes = bytes }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return lock.withLock {
                let count = min(Int(size), bytes.count - position)
                guard count > 0 else { return 0 }
                bytes.withUnsafeBytes { _ = memcpy(buffer, $0.baseAddress! + position, count) }
                position += count
                return Int32(count)
            }
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        var rebases = 0
    }

    private func produce(_ bytes: Data, after predecessor: HLSSegmentProducer? = nil, cache shared: SegmentCache? = nil,
                         keep: ((HLSSegmentProducer, SegmentCache) -> Void)? = nil) async throws -> (written: Int, rebases: Int) {
        let demuxer = Demuxer()
        try demuxer.open(reader: Reader(bytes), formatHint: "mpegts")
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        var audio: HLSSegmentProducer.AudioConfig?
        if let s = demuxer.stream(at: demuxer.audioStreamIndex) {
            audio = .init(codecpar: UnsafePointer(s.pointee.codecpar), timeBase: s.pointee.time_base,
                          sourceStreamIndex: demuxer.audioStreamIndex, inputTimeBase: s.pointee.time_base,
                          sourceTimeBase: s.pointee.time_base, bridge: nil, stripAacAdts: true)
        }
        let cache = shared ?? SegmentCache(forwardWindow: 400, backwardWindow: 400)
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: index,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar), timeBase: stream.pointee.time_base,
                         codecTagOverride: "avc1"),
            audio: audio, cache: cache, baseIndex: shared == nil ? 0 : cache.count, targetSegmentDurationSeconds: 2,
            videoFallbackDurationPts: 3_600, desiredFirstVideoTfdtPts: shared == nil ? 0 : Int64(cache.count) * 180_000,
            segmentBoundaries: [], isLive: true, bufferAheadSegments: 400)
        if let predecessor { producer.continueLiveReplayHistory(from: predecessor) }
        let box = Box()
        producer.onPumpFinished = { reason in print("PUMP \(reason)"); box.lock.withLock { box.done = true } }
        producer.onLiveTimelineRebase = { _, _ in box.lock.withLock { box.rebases += 1 } }
        producer.onLiveSegmentFinalized = { _, _, _, _ in }
        producer.start()
        try await waitFor(upTo: .seconds(240)) { box.lock.withLock { box.done } }
        let written = producer.packetsWrittenCount
        if let keep { keep(producer, cache) } else { producer.stop() }
        return (written, box.lock.withLock { box.rebases })
    }

    /// As the engine does it: the reset clock ends the first pump (`sourceReplay`), a fresh producer reads the
    /// new connection and continues the first one's replay history.
    private func reconnect(_ first: Data, _ second: Data) async throws -> Int {
        var held: (HLSSegmentProducer, SegmentCache)?
        _ = try await produce(first, keep: { held = ($0, $1) })
        let (old, cache) = try #require(held)
        let written = try await produce(second, after: old, cache: cache).written
        old.stop()
        return written
    }

    @Test func replayWithResetClockPlaysOnce() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let a = env["AETHER_REPLAY_A"], let b = env["AETHER_REPLAY_B"],
              let first = FileManager.default.contents(atPath: a),
              let second = FileManager.default.contents(atPath: b) else { return }
        EngineLog.handler = { line in
            if line.contains("LiveRebase") || line.contains("pump finished") || line.contains("replay history") { print("LOG " + line.prefix(220)) }
        }
        let secondAlone = try await produce(second).written
        LiveTimestampRebaser.isEnabled = false
        let without = try await reconnect(first, second)
        LiveTimestampRebaser.isEnabled = true
        let with = try await reconnect(first, second)
        print("REPLAY second connection alone=\(secondAlone) after reconnect: without fix=\(without) with fix=\(with)")
        #expect(with < without - 500, "the repeated ~20 s must not be written again")
    }
}
