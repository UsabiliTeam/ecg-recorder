import Foundation

/// Is the signal clean enough to trust? Two standard checks, either of which marks it noisy:
/// - ECG kurtosis over the last 10 s (kSQI; Li, Mark & Clifford 2008, Physiol Meas 29(1)). A clean ECG is mostly
///   flat with sharp QRS spikes, so its kurtosis is high (typically 10-30 on the H10); noise from dry electrodes,
///   a loose strap or movement pulls it towards 3 (Gaussian). Below 5 counts as noisy.
/// - The share of the last 30 intervals flagged as artifacts or no-contact (`LiveAnalyzer.artifactShare`), over
///   20%. Lower would fire on healthy people: one ectopic beat flags two intervals, and two ectopics in 30 beats
///   (seen in a clean real recording) are already 13%.
/// It cannot tell a loose strap from a badly placed one; it says the signal is poor and what usually fixes it.
/// Thresholds are first estimates, to be checked on recordings made with a dry or loose strap
/// (`tools/signal_quality.py` prints both numbers for a CSV).
enum SignalQuality {
    static let seconds = 10
    static let cleanKurtosis = 5.0
    static let maxArtifactShare = 0.2

    static func isNoisy(kurtosis: Double?, artifactShare: Double?) -> Bool {
        if let k = kurtosis, k < cleanKurtosis { return true }
        if let share = artifactShare, share > maxArtifactShare { return true }
        return false
    }

    /// Kurtosis (not excess) of ECG samples after removing a 1 s moving average, so baseline wander from breathing
    /// doesn't hide the QRS spikes. Nil with less than `seconds` of signal or a flat line.
    static func kurtosis(_ samples: [Float], rate: Int = LiveBuffer.rate) -> Double? {
        let n = samples.count
        guard n >= seconds * rate else { return nil }
        let half = rate / 2
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(samples[i]) }
        let y = (0..<n).map { i -> Double in
            let lo = max(0, i - half), hi = min(n, i + half + 1)
            return Double(samples[i]) - (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
        let mean = y.reduce(0, +) / Double(n)
        var m2 = 0.0, m4 = 0.0
        for v in y {
            let d = (v - mean) * (v - mean)
            m2 += d
            m4 += d * d
        }
        m2 /= Double(n); m4 /= Double(n)
        return m2 > 0 ? m4 / (m2 * m2) : nil
    }
}
