import Foundation

extension IndexPoint {
    func value(_ metric: Metric) -> Double? {
        switch metric {
        case .hr: hr
        case .rmssd: rmssd
        case .sdnn: sdnn
        case .pnn50: pnn50
        }
    }
}

enum ChartData {
    /// Flattens series (label -> index points) into chart points for one metric; gaps stay gaps.
    static func points(_ series: [String: [IndexPoint]], metric: Metric) -> [ChartPoint] {
        var out: [ChartPoint] = []
        for label in series.keys.sorted() {
            for p in series[label] ?? [] {
                guard let v = p.value(metric) else { continue }
                out.append(ChartPoint(id: out.count, series: label, time: Date(timeIntervalSince1970: p.t), value: v))
            }
        }
        return out
    }
}
