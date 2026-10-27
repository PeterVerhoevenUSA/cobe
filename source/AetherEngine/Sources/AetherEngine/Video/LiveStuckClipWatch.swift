import Foundation

/// Some live origins get stuck: every connection sends the very same clip (seen on an Xtream restream of a live channel,
/// the same 24 s, 100.1 s to 124.2 s on its own clock, every 20 s, for hours). Nothing can be shown live from
/// such a copy; the host should switch to another one. This watch spots a source that restarts at the same
/// point of its own clock again and again.
public enum LiveStuckClip {
    /// Called (any thread) when the playing live source keeps sending the same clip.
    public static var onStuck: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStuck }
        set { lock.lock(); _onStuck = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _onStuck: (@Sendable () -> Void)?
}

/// Pump-thread-only.
struct LiveStuckClipWatch {
    private var restarts: [Double] = []
    private(set) var reported = false
    /// The same restart point this many times in a row (with the first time) is a stuck source.
    /// Twice at the same point: about 40 s of the clip, not two minutes.
    static let repeatsToReport = 2
    /// Within one frame is "the same point".
    static let toleranceSeconds = 0.05

    /// A backward jump of the source clock to `seconds` (a reconnect); true once the source counts as stuck.
    mutating func restarted(atSeconds seconds: Double) -> Bool {
        guard !reported else { return false }
        if let last = restarts.last, abs(last - seconds) > Self.toleranceSeconds { restarts = [] }
        restarts.append(seconds)
        if restarts.count >= Self.repeatsToReport { reported = true }
        return reported
    }
}
