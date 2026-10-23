import Foundation

/// RR artifact detection after Lipponen & Tarvainen (2019), "A robust algorithm for heart rate variability time
/// series artefact correction using novel beat classification", J Med Eng Technol 43(3) - the method behind
/// Kubios' automatic correction. Thresholds adapt to the recording (quartile deviation of the successive
/// differences over 91 beats), so large breathing-driven swings in relaxed, high-HRV people stay normal while
/// ectopic, missed and extra beats are caught. `tools/signal_quality.py` is the same algorithm in Python.
///
/// It needs the two beats after a beat to judge it, so it runs over whole recordings (saved and rebuilt numbers)
/// and over a trailing buffer for the live view (`LiveAnalyzer`), never beat by beat into the file.
enum ArtifactDetector {
    enum Kind: String, CaseIterable, Sendable {
        case ectopic, missed, extra, longShort = "long_short"
    }

    static let alpha = 5.2
    static let c1 = 0.13
    static let c2 = 0.17
    static let thresholdBeats = 91
    static let medianBeats = 11
    /// Floor (ms) for both thresholds: a perfectly regular series (a pacemaker, simulated data) has a quartile
    /// deviation of 0, which would make every tiny change look huge.
    static let minimumThreshold = 10.0

    /// One label (or nil) per interval of an uninterrupted run of intervals (ms).
    static func classify(_ rr: [Double]) -> [Kind?] {
        let n = rr.count
        var kinds = [Kind?](repeating: nil, count: n)
        guard n >= 4 else { return kinds }

        // Successive differences, normalized by their own adaptive threshold.
        var drr = [0.0] + (1..<n).map { rr[$0] - rr[$0 - 1] }
        let th1 = threshold(drr)
        for i in 0..<n { drr[i] /= th1[i] }
        func d(_ i: Int) -> Double {                 // mirrored at the ends
            let j = i < 0 ? -i : (i >= n ? 2 * (n - 1) - i : i)
            return drr[j]
        }
        // Deviation from the local median; shorter-than-median counts double (short beats are the telling ones).
        let half = medianBeats / 2
        let med = (0..<n).map { median(rr[max(0, $0 - half)..<min(n, $0 + half + 1)]) }
        let mrr = (0..<n).map { (rr[$0] - med[$0]) * (rr[$0] < med[$0] ? 2 : 1) }
        let th2 = threshold(mrr)
        let nmrr = (0..<n).map { mrr[$0] / th2[$0] }

        // The short interval before an ectopic beat is first seen as long/short; the ectopic verdict is more specific.
        func mark(_ i: Int, _ kind: Kind) {
            guard i >= 0, i < n, kinds[i] == nil || (kinds[i] == .longShort && kind == .ectopic) else { return }
            kinds[i] = kind
        }

        for i in 0..<(n - 2) where abs(drr[i]) > 1 {
            let s12 = drr[i] > 0 ? max(d(i - 1), d(i + 1)) : min(d(i - 1), d(i + 1))
            if (drr[i] > 1 && s12 < -c1 * drr[i] - c2) || (drr[i] < -1 && s12 > -c1 * drr[i] + c2) {
                // The ectopic beat ends interval i - 1 and starts interval i: both are wrong.
                mark(i - 1, .ectopic); mark(i, .ectopic)
                continue
            }
            let candidates = abs(d(i + 1)) < abs(d(i + 2)) ? [i, i + 1] : [i]
            for j in candidates {
                let s22 = drr[j] >= 0 ? min(d(j + 1), d(j + 2)) : max(d(j + 1), d(j + 2))
                let long = drr[j] > 1 && s22 < -1
                let short = drr[j] < -1 && s22 > 1
                guard long || short || abs(nmrr[j]) > 3 else { continue }
                if short, j + 1 < n, abs(rr[j] + rr[j + 1] - med[j]) < th2[j] {
                    mark(j, .extra); mark(j + 1, .extra)       // one true interval split in two
                } else if long, abs(rr[j] / 2 - med[j]) < th2[j] {
                    mark(j, .missed)                          // two true intervals seen as one
                } else {
                    mark(j, .longShort)
                }
            }
        }
        return kinds
    }

    /// alpha x quartile deviation of |values| over a centred window, clipped at the ends.
    private static func threshold(_ values: [Double]) -> [Double] {
        let n = values.count, half = thresholdBeats / 2
        let magnitudes = values.map(abs)
        return (0..<n).map { i in
            let window = magnitudes[max(0, i - half)..<min(n, i + half + 1)].sorted()
            return max(minimumThreshold, alpha * (quantile(window, 0.75) - quantile(window, 0.25)) / 2)
        }
    }

    /// Linear interpolation between order statistics (the pandas / numpy default).
    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        let position = q * Double(sorted.count - 1)
        let lower = Int(position), upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    private static func median(_ values: ArraySlice<Double>) -> Double {
        let s = values.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}

/// One RR interval as the file holds it: the rounded value, the device's own verdict (`no_contact`,
/// `implausible_rr`), when its row arrived, and the heart rate reported with it.
struct BeatRecord: Sendable {
    let rr: Double
    let deviceFlag: String?
    let t: Double
    let hr: Int?
    /// Beats were lost just before this one (a link event or a silence), so it doesn't follow the previous beat.
    let afterGap: Bool
}

extension ArtifactDetector {
    /// The final flag of every beat: the device's flag, else an artifact label, else nil (normal). Runs are cut at
    /// gaps and at device-flagged beats, because the intervals on either side of those aren't successive.
    static func flags(_ beats: [BeatRecord]) -> [String?] {
        var out = [String?](repeating: nil, count: beats.count)
        var run: [Int] = []
        func flush() {
            let kinds = classify(run.map { beats[$0].rr })
            for (k, i) in zip(kinds, run) { out[i] = k?.rawValue }
            run = []
        }
        for (i, beat) in beats.enumerated() {
            if beat.afterGap { flush() }
            if let flag = beat.deviceFlag { flush(); out[i] = flag } else { run.append(i) }
        }
        flush()
        return out
    }
}
