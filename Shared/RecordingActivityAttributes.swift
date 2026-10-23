import ActivityKit
import Foundation

/// What the lock screen and Dynamic Island show while recording. Shared by the app and the widget extension.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Devices currently streaming, out of `total`.
        var connected: Int
        var total: Int
        /// Only sent for a single device: its heart rate and zone (nil while not streaming or zones are off).
        var hr: Int?
        var zone: Int?
        var zoneLevel: ZoneLevel?
        /// Set while "Skip first" is counting down; the clock counts down to it and nothing is written yet.
        var startsAt: Date?
        /// When the file started; the clock counts up from here without the app sending updates.
        var startedAt: Date?
        /// When auto-stop is on, the deadline the clock counts down to instead.
        var autoStopAt: Date?

        var isComplete: Bool { connected == total }
    }

    /// Effort colour for the zone: easy is green, moderate yellow, hard red.
    enum ZoneLevel: String, Codable, Hashable { case easy, moderate, hard }

    /// Times live in `ContentState`, not here, so the activity can be shown the moment Record is tapped
    /// (iOS only allows starting one while the app is in front) and then move on to recording.
    let name: String
}
