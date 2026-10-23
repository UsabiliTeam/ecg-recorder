import Foundation

enum Format {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    /// "42 s", "7 min", "1 h 05 min". Short recordings show seconds so they never read as "0 min".
    static func duration(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        return minutes >= 60 ? String(format: "%d h %02d min", minutes / 60, minutes % 60) : "\(minutes) min"
    }

    /// Elapsed time on a chart axis: "0:45", "12:30", "1:05:00".
    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Live timer: ":06", then "1:06", then "1:02:06".
    static func liveClock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return String(format: ":%02d", s) }
        return s < 3600 ? String(format: "%d:%02d", s / 60, s % 60) : String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Three-letter English weekday, independent of the phone's language.
    static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        weekdays[calendar.component(.weekday, from: date) - 1]
    }

    /// How a device is named on screen. All real devices are H10s, so the model is left out:
    /// the last four characters of the ID ("FB35"), or the full ID in lists; simulated ones by name.
    static func device(_ id: String, short: Bool = true) -> String {
        if DeviceID.isSimulated(id) || !short { return id }
        return String(id.suffix(4))
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// "Predicted RMSSD 45 ms" and "Recorded RMSSD 52 ms", after a recording made with a prediction. Plain numbers,
    /// no verdict. The prediction is only stored; it never enters any calculation.
    static func predictionSummary(_ session: Session) -> String? {
        guard let guess = session.predictedRMSSD else { return nil }
        let actual = session.avgRMSSD.map { String(format: "%.0f ms", $0) } ?? "–"
        return "Predicted RMSSD: \(guess) ms\nRecorded RMSSD: \(actual)"
    }

    /// Default name for the first recording of a day, "MoRe29/09" (day/month).
    static func morningName(_ date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.component(.day, from: date), month = calendar.component(.month, from: date)
        return String(format: "MoRe%02d/%02d", day, month)
    }

    /// Name used when the recording name is left empty: "MoRe29/09" for the day's first recording, then
    /// "Tue01", "Tue02", ... (three-letter weekday and a count that restarts each day).
    static func defaultTag(now: Date, existing: [(tag: String, start: Date)], calendar: Calendar = .current) -> String {
        let today = existing.filter { calendar.isDate($0.start, inSameDayAs: now) }
        if today.isEmpty { return morningName(now, calendar: calendar) }
        let prefix = weekday(now, calendar: calendar)
        let used = today.compactMap { s -> Int? in
            s.tag.hasPrefix(prefix) ? Int(s.tag.dropFirst(prefix.count)) : nil
        }
        return prefix + String(format: "%02d", (used.max() ?? 0) + 1)
    }
}
