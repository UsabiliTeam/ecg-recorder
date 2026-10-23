import Foundation

/// Normal-to-normal (NN) intervals in a window. `diffs` holds successive differences of *adjacent* NN pairs only:
/// two normal beats separated by a flagged interval or a data gap are not successive, so their difference would
/// inflate RMSSD and pNN50 (the Task Force 1996 definitions are over successive NN intervals).
struct NNWindow {
    let nn: [Double]
    let diffs: [Double]
}

extension NNWindow {
    /// An uninterrupted run of NN intervals: every neighbouring pair is successive.
    init(contiguous rr: [Double]) {
        nn = rr
        diffs = zip(rr.dropFirst(), rr).map { $0 - $1 }
    }
}

/// A metric is a pure function over the NN intervals (ms) inside the rolling window.
/// Add a new metric by adding a type and registering it in `MetricPipeline.standard`; nothing else changes.
protocol RRMetric: Sendable {
    var name: String { get }
    func value(_ window: NNWindow) -> Double?
}

extension RRMetric {
    /// Value over an uninterrupted run of NN intervals.
    func value(rr: [Double]) -> Double? { value(NNWindow(contiguous: rr)) }
}

struct RMSSD: RRMetric {
    let name = "rmssd"
    func value(_ w: NNWindow) -> Double? {
        guard !w.diffs.isEmpty else { return nil }
        return (w.diffs.reduce(0) { $0 + $1 * $1 } / Double(w.diffs.count)).squareRoot()
    }
}

struct SDNN: RRMetric {
    let name = "sdnn"
    func value(_ w: NNWindow) -> Double? {
        let rr = w.nn
        guard rr.count >= 2 else { return nil }
        let mean = rr.reduce(0, +) / Double(rr.count)
        let variance = rr.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rr.count - 1)
        return variance.squareRoot()
    }
}

struct PNN50: RRMetric {
    let name = "pnn50"
    func value(_ w: NNWindow) -> Double? {
        guard !w.diffs.isEmpty else { return nil }
        return Double(w.diffs.filter { abs($0) > 50 }.count) / Double(w.diffs.count) * 100
    }
}

enum RRQuality {
    static let plausible = 300.0...2000.0
    /// The flags the device side decides, one interval at a time. They are the only flags written to the CSV;
    /// artifacts (`ArtifactDetector`) need the beats around an interval and are computed from the file.
    static let deviceFlags: Set<String> = ["no_contact", "implausible_rr"]

    /// Returns a flag for intervals that must not enter the metrics; they are still written to the CSV, flagged.
    static func flag(rr: Double, contact: Bool?) -> String? {
        if contact == false { return "no_contact" }
        return plausible.contains(rr) ? nil : "implausible_rr"
    }

    /// The H10 measures RR in 1/1024 s. The CSV keeps 0.1 ms; every calculation uses this same rounded value,
    /// so numbers computed live match numbers recomputed from the file.
    static func rounded(_ ms: Double) -> Double { (ms * 10).rounded() / 10 }
}

/// Rolling window over the RR stream. The window is measured in beat time (every interval, flagged or not,
/// counts as elapsed time), so it is independent of Bluetooth arrival jitter. Only normal intervals enter the
/// metrics. Nothing is reported until the window holds `minimumSeconds` of NN intervals: RMSSD from a handful
/// of beats is noise (ultra-short HRV needs about 30 s).
struct MetricPipeline {
    static let standard: [any RRMetric] = [RMSSD(), SDNN(), PNN50()]

    let windowSeconds: Double
    let minimumSeconds: Double
    private let metrics: [any RRMetric]
    private var beats: [(rr: Double, normal: Bool)] = []
    private var total = 0.0

    init(windowSeconds: Int, metrics: [any RRMetric] = MetricPipeline.standard) {
        self.windowSeconds = Double(windowSeconds)
        minimumSeconds = min(30, Double(windowSeconds) / 2)
        self.metrics = metrics
    }

    /// Adds one interval (`normal` = unflagged) and returns every metric's value for the updated window,
    /// or nothing while there is too little clean data.
    mutating func add(rr: Double, normal: Bool) -> [String: Double] {
        beats.append((rr, normal))
        total += rr
        var drop = 0
        while total / 1000 > windowSeconds, drop < beats.count - 1 { total -= beats[drop].rr; drop += 1 }
        if drop > 0 { beats.removeFirst(drop) }
        return evaluate(beats[...])
    }

    /// Every metric over `window` (already cut to the window length), or nothing with too little clean data.
    func evaluate(_ window: ArraySlice<(rr: Double, normal: Bool)>) -> [String: Double] {
        var nn: [Double] = []
        var diffs: [Double] = []
        var previous: (rr: Double, normal: Bool)?
        for beat in window {
            if beat.normal {
                if let p = previous, p.normal { diffs.append(beat.rr - p.rr) }
                nn.append(beat.rr)
            }
            previous = beat
        }
        guard nn.reduce(0, +) / 1000 >= minimumSeconds else { return [:] }
        let w = NNWindow(nn: nn, diffs: diffs)
        var out: [String: Double] = [:]
        for metric in metrics { if let v = metric.value(w) { out[metric.name] = v } }
        return out
    }

    /// Data was lost: beats on either side of the gap are neither successive nor in the same time window.
    mutating func reset() { beats = []; total = 0 }
}

/// Whole-recording totals in constant memory: mean HR from NN intervals and RMSSD over every adjacent NN pair.
struct NNSummary: Sendable {
    /// Below this much clean data a whole-recording RMSSD is not reported.
    static let minimumSeconds = 30.0

    private(set) var intervals = 0
    private(set) var flagged = 0
    /// Flagged intervals by flag, for the file's own quality statement.
    private(set) var flagCounts: [String: Int] = [:]
    private var nnCount = 0
    private var nnSum = 0.0
    private var squaredDiffs = 0.0
    private var diffCount = 0
    private var previousNN: Double?

    mutating func add(rr: Double, flag: String?) {
        intervals += 1
        if let flag {
            flagged += 1
            flagCounts[flag, default: 0] += 1
            previousNN = nil
            return
        }
        if let p = previousNN { squaredDiffs += (rr - p) * (rr - p); diffCount += 1 }
        previousNN = rr
        nnCount += 1
        nnSum += rr
    }

    mutating func breakSequence() { previousNN = nil }

    /// 60 000 / mean NN: the standard mean HR, independent of how often the device reports bpm.
    var meanHR: Double? { nnCount > 0 ? 60_000 / (nnSum / Double(nnCount)) : nil }
    var rmssd: Double? {
        guard diffCount > 0, nnSum / 1000 >= Self.minimumSeconds else { return nil }
        return (squaredDiffs / Double(diffCount)).squareRoot()
    }

    /// Appended to the `session_stop` note so the file states its own summary and data quality:
    /// `rr_flagged` is the total, followed by the count of each flag that occurred (`rr_ectopic=2;...`).
    var note: String {
        var s = ""
        if let hr = meanHR { s += ";mean_hr_bpm=\(String(format: "%.1f", hr))" }
        if let r = rmssd { s += ";rmssd_ms=\(String(format: "%.1f", r))" }
        s += ";rr_count=\(intervals);rr_flagged=\(flagged)"
        for (flag, count) in flagCounts.sorted(by: { $0.key < $1.key }) { s += ";rr_\(flag)=\(count)" }
        return s
    }
}

/// A silence this long between RR arrivals means beats were lost (a normal H10 stream reports every ~1 s,
/// and an interval is at most 2 s).
enum BeatTiming {
    static let gapSeconds = 5.0
    /// The index keeps one point per this many seconds.
    static let traceInterval = 5.0
}

/// Everything saved about one participant's RR stream: whole-recording totals and the index trace.
/// The engine and the index rebuilder feed it the same beats (values, device flags, row times, HR, gaps) and it
/// only computes at the end, over the whole recording, so saved and rebuilt numbers come from one piece of code
/// and artifact detection sees the beats after each interval too.
struct RecordingAnalysis: Sendable {
    struct Result: Sendable {
        let summary: NNSummary
        let trace: [IndexPoint]
    }

    let windowSeconds: Int
    private var beats: [BeatRecord] = []
    private var lastArrival: Double?
    private var gapPending = false

    init(windowSeconds: Int) { self.windowSeconds = windowSeconds }

    /// One interval as written to the file; `t` is its row's `unix_time_s` (arrival time, ms precision).
    mutating func add(rr: Double, deviceFlag: String?, at t: Double, hr: Int?) {
        let silent = lastArrival.map { t - $0 > BeatTiming.gapSeconds } ?? false
        beats.append(BeatRecord(rr: rr, deviceFlag: deviceFlag, t: t, hr: hr, afterGap: gapPending || silent))
        lastArrival = t
        gapPending = false
    }

    /// Link lost, no data, or a resume: the next beat doesn't follow the previous one.
    mutating func gap() { gapPending = !beats.isEmpty }

    func finish() -> Result {
        let flags = ArtifactDetector.flags(beats)
        var window = MetricPipeline(windowSeconds: windowSeconds)
        var summary = NNSummary()
        var trace: [IndexPoint] = []
        var latest: [String: Double] = [:]
        var lastPoint = -Double.infinity
        for (beat, flag) in zip(beats, flags) {
            if beat.afterGap { window.reset(); summary.breakSequence() }
            latest = window.add(rr: beat.rr, normal: flag == nil)
            summary.add(rr: beat.rr, flag: flag)
            // Sampled at RR arrivals, at most every `traceInterval` seconds.
            if beat.t - lastPoint >= BeatTiming.traceInterval {
                lastPoint = beat.t
                trace.append(IndexPoint(t: beat.t, hr: beat.hr.flatMap { $0 > 0 ? Double($0) : nil },
                                        rmssd: latest["rmssd"], sdnn: latest["sdnn"], pnn50: latest["pnn50"]))
            }
        }
        return Result(summary: summary, trace: trace)
    }
}

/// The live numbers on screen: the same artifact detection and window, run over a trailing buffer each beat.
/// The two newest beats wait for the beats after them before they count, so a premature beat never makes the
/// number jump. Artifacts it finds are for the screen only; the file keeps the raw beats.
struct LiveAnalyzer {
    static let pending = 2
    /// Beats of history kept before the window, so artifact thresholds have context.
    private static let context = ArtifactDetector.thresholdBeats / 2 + 2
    /// Recent decided beats the artifact share is measured over.
    static let shareBeats = 30

    private let pipeline: MetricPipeline
    private var beats: [BeatRecord] = []
    private var lastArrival: Double?
    private(set) var latest: [String: Double] = [:]
    /// Share of the last `shareBeats` decided beats that were flagged; nil until there are that many.
    private(set) var artifactShare: Double?

    init(windowSeconds: Int) { pipeline = MetricPipeline(windowSeconds: windowSeconds) }

    mutating func add(rr: Double, deviceFlag: String?, at t: Double) {
        if let last = lastArrival, t - last > BeatTiming.gapSeconds { gap() }
        lastArrival = t
        beats.append(BeatRecord(rr: rr, deviceFlag: deviceFlag, t: t, hr: nil, afterGap: false))
        trim()
        let flags = ArtifactDetector.flags(beats)
        let decided = max(0, beats.count - Self.pending)
        var window: [(rr: Double, normal: Bool)] = []
        var total = 0.0
        for i in stride(from: decided - 1, through: 0, by: -1) {
            total += beats[i].rr
            if total / 1000 > pipeline.windowSeconds, !window.isEmpty { break }
            window.append((beats[i].rr, flags[i] == nil))
        }
        latest = pipeline.evaluate(window.reversed()[...])
        let recent = flags[max(0, decided - Self.shareBeats)..<decided]
        artifactShare = recent.count < Self.shareBeats ? nil : Double(recent.filter { $0 != nil }.count) / Double(recent.count)
    }

    /// Link lost or silent: start over; beats across the gap are neither successive nor in one window.
    mutating func gap() {
        beats = []
        latest = [:]
        artifactShare = nil
    }

    /// Keeps the window plus `context` beats before it.
    private mutating func trim() {
        var total = 0.0, keep = 0
        for beat in beats.reversed() {
            keep += 1
            total += beat.rr
            if total / 1000 > pipeline.windowSeconds { break }
        }
        let drop = beats.count - (keep + Self.pending + Self.context)
        if drop > 0 { beats.removeFirst(drop) }
    }
}
