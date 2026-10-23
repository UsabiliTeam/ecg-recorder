import Foundation

/// Ring buffer of recent ECG samples for the waveform. Written by the engine, read by the UI at ~30 Hz.
/// The UI only ever reads this copy; it has no path back into the recorder.
final class LiveBuffer: @unchecked Sendable {
    static let rate = 130
    /// 10 s: the waveform shows up to 6 s, and `SignalQuality` judges the last 10 s.
    private let capacity = 130 * 10
    private var samples: [Float]
    private var head = 0
    private var count = 0
    private var lastAppend = 0.0
    private let lock = NSLock()

    init() { samples = [Float](repeating: 0, count: capacity) }

    func append(_ values: [Int32]) {
        lock.lock(); defer { lock.unlock() }
        lastAppend = Date().timeIntervalSince1970
        for v in values {
            samples[head] = Float(v)
            head = (head + 1) % capacity
            count = min(count + 1, capacity)
        }
    }

    /// The most recent `n` samples, oldest first.
    func latest(_ n: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let take = min(n, count)
        return (0..<take).map { samples[(head - take + $0 + capacity) % capacity] }
    }

    /// Recent samples plus the seconds since the last packet, read under one lock.
    func snapshot(_ n: Int, now: Double) -> (samples: [Float], age: Double) {
        lock.lock(); defer { lock.unlock() }
        let take = min(n, count)
        let out = (0..<take).map { samples[(head - take + $0 + capacity) % capacity] }
        return (out, count == 0 ? .infinity : max(0, now - lastAppend))
    }

    /// False when no ECG arrived recently, e.g. the device streams HR but not ECG.
    var isFresh: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince1970 - lastAppend < 3
    }

    func clear() {
        lock.lock(); count = 0; lock.unlock()
    }
}
