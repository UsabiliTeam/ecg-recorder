import Foundation

/// An experimental condition the user defines in Settings ("Baseline", "Questionnaire", ...). Tapping it while
/// recording marks when that condition starts.
struct ConditionLabel: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// Position in `Palette.labels`.
    var colorIndex: Int

    init(name: String, colorIndex: Int) {
        id = UUID()
        self.name = name
        self.colorIndex = colorIndex
    }

    static let presets = ["Baseline", "Questionnaire", "Positive", "Negative"]
    static let maxCount = 12
    static let maxNameLength = 32
}

/// One tap in the label panel; one LABEL row in the CSV (session-level, `note` = label name, `flag` = kind,
/// empty for a start).
struct LabelEvent: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The label's condition begins and runs until the next start or end.
        case start = ""
        /// Closes the running condition; the time until the next start belongs to no label.
        case end
        /// Takes back the most recent start or end that is still in effect.
        case undo
    }

    /// Unix seconds, at the file's millisecond precision.
    let t: Double
    let kind: Kind
    let name: String
}

/// A stretch of time one label was active.
struct LabelSpan: Codable, Hashable, Sendable {
    let name: String
    let start: Double
    let end: Double
}

/// Reads a sequence of label taps the way an analysis of the CSV should: undo removes the latest start or end
/// still in effect, and each start runs until the next start, end, or the end of the recording.
enum LabelTimeline {
    static func applied(_ events: [LabelEvent]) -> [LabelEvent] {
        var kept: [LabelEvent] = []
        for e in events {
            if e.kind == .undo { _ = kept.popLast() } else { kept.append(e) }
        }
        return kept
    }

    static func spans(_ events: [LabelEvent], until end: Double) -> [LabelSpan] {
        let kept = applied(events)
        return kept.enumerated().compactMap { i, e in
            guard e.kind == .start else { return nil }
            let stop = i + 1 < kept.count ? kept[i + 1].t : end
            return LabelSpan(name: e.name, start: e.t, end: max(e.t, stop))
        }
    }

    /// The label running now, if any.
    static func active(_ events: [LabelEvent]) -> LabelEvent? {
        applied(events).last.flatMap { $0.kind == .start ? $0 : nil }
    }
}
