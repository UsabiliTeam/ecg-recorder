import Foundation

/// Hard limits, kept in one place so UI and state layers agree.
enum Limits {
    static let maxDevices = 6
    static let maxPseudonymLength = 32
    static let maxTagLength = 40
    static let deviceIDLength = 8
}

enum LinkState: Sendable {
    case disconnected, connecting, connected, streaming, noData

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .streaming: "Streaming"
        case .noData: "No data"
        }
    }
}

struct Participant: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    /// Permanent once created.
    let pseudonym: String
    /// Position in the participant palette; nil for participants saved before colours existed.
    let colorIndex: Int?

    init(pseudonym: String, colorIndex: Int? = nil) {
        id = UUID()
        self.pseudonym = pseudonym
        self.colorIndex = colorIndex
    }
}

/// One participant-to-device pairing in the session being set up or recorded.
struct Slot: Identifiable, Sendable {
    let id = UUID()
    var participantID: UUID?
    var deviceID: String?
    var state: LinkState = .disconnected
    var hr = 0
    var rmssd: Double?
    var battery: Int?
    /// Since when this device has not been streaming; nil while it streams. Drives the connection advice.
    var waitingSince: Date?
    /// True once this device has delivered data; false on a tile means "not recording yet".
    var hasStreamed = false
    /// Since when the signal has looked noisy; nil while it is clean. Drives the "Noisy signal" advice.
    var noisySince: Date?

    var isStreaming: Bool { state == .streaming }
}

struct Session: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let start: Date
    let duration: TimeInterval
    let tag: String
    let participants: [String]
    /// CSV file name inside the Documents folder.
    let fileName: String
    /// Whole-recording values, only set for a single-participant recording: mean HR from NN intervals, and
    /// RMSSD over every adjacent NN pair (not an average of windowed values). Nil with under 30 s of clean data.
    let avgHR: Double?
    let avgRMSSD: Double?
    /// RMSSD (ms) the user guessed before recording, when they chose to.
    let predictedRMSSD: Int?
    /// Events marked during the recording. Optional so index entries saved before markers existed still decode.
    let markers: [EventMarker]?
    /// When each condition label was active, after undos. Optional for the same reason as `markers`.
    let labels: [LabelSpan]?

    init(id: UUID, start: Date, duration: TimeInterval, tag: String, participants: [String], fileName: String,
        avgHR: Double? = nil, avgRMSSD: Double? = nil, predictedRMSSD: Int? = nil, markers: [EventMarker]? = nil,
        labels: [LabelSpan]? = nil) {
        self.id = id
        self.start = start
        self.duration = duration
        self.tag = tag
        self.participants = participants
        self.fileName = fileName
        self.avgHR = avgHR
        self.avgRMSSD = avgRMSSD
        self.predictedRMSSD = predictedRMSSD
        self.markers = markers
        self.labels = labels
    }

    var title: String { tag.isEmpty ? "Recording" : tag }
    var subtitle: String { "\(start.formatted(date: .abbreviated, time: .shortened)) · \(Format.duration(duration))" }

    /// ECGRecorder_YYYYMMDD_HHMMSS[_tag].csv, with the tag reduced to file-safe characters.
    static let fileNamePrefix = "ECGRecorder_"
    /// Recordings made before the app was renamed from ECG Collector used this prefix; still recognized.
    static let legacyFileNamePrefix = "ECGCollector_"

    static func fileName(start: Date, tag: String) -> String {
        let suffix = tag.isEmpty ? "" : "_" + Validation.fileSafe(tag)
        return "\(fileNamePrefix)\(Format.fileStamp.string(from: start))\(suffix).csv"
    }
}

/// A moment the user marked while recording: "event01", or a name they gave it. One MARKER row in the CSV.
struct EventMarker: Codable, Hashable, Sendable {
    /// Unix seconds, at the file's millisecond precision.
    let t: Double
    let name: String

    static func defaultName(_ number: Int) -> String { String(format: "event%02d", number) }
}

enum Metric: String, CaseIterable, Identifiable, Sendable {
    case rmssd, sdnn, pnn50, hr

    var id: String { rawValue }
    var title: String {
        switch self {
        case .rmssd: "RMSSD"
        case .sdnn: "SDNN"
        case .pnn50: "pNN50"
        case .hr: "HR"
        }
    }
    var unit: String {
        switch self {
        case .rmssd, .sdnn: "ms"
        case .pnn50: "%"
        case .hr: "bpm"
        }
    }
    /// Graphs shown first, stacked in this order, and the ones the user can add.
    /// pNN50 needs long recordings, so a single recording doesn't offer it.
    static let recordingDefaults: [Metric] = [.hr, .rmssd]
    static let recordingOptional: [Metric] = [.sdnn]
    static let participantDefaults: [Metric] = [.hr, .rmssd]
    static let participantOptional: [Metric] = [.sdnn, .pnn50]
}

struct ChartPoint: Identifiable, Sendable {
    let id: Int
    let series: String
    let time: Date
    let value: Double
}

enum HRMaxMethod: String, CaseIterable, Identifiable, Codable {
    case ageBased = "Age-based", dataDerived = "Data-derived", none = "None"
    var id: String { rawValue }
}

enum AlertChannel: String, CaseIterable, Identifiable, Codable {
    case sound = "Sound", haptic = "Haptic", onScreen = "On-screen", lockScreen = "Lock-screen notification"
    var id: String { rawValue }
}

/// Things the app alerts about; each can be switched off in Settings > Notifications. Saving problems and a
/// recording resumed after a restart are always announced, because they are about the data itself.
enum AlertEvent: String, CaseIterable, Identifiable, Codable {
    case timerEnds, started, saved, deviceLost, notReady, bluetooth, storage

    var id: String { rawValue }
    var title: String {
        switch self {
        case .timerEnds: "Timer ends"
        case .started: "Recording starts"
        case .saved: "Recording saved"
        case .deviceLost: "A device drops out"
        case .notReady: "A device isn't ready at start"
        case .bluetooth: "Bluetooth problems"
        case .storage: "Storage almost full"
        }
    }
}

enum HRZone {
    /// Placeholder until the max-HR method is decided.
    static let assumedMaxHR = 190.0

    enum Level { case easy, moderate, hard }

    /// Zones 1-2 are comfortable aerobic effort (green), zone 3 is tempo, near the aerobic threshold (yellow),
    /// zones 4-5 are near or above the anaerobic threshold (red).
    static func level(zone: Int) -> Level {
        switch zone {
        case ...2: .easy
        case 3: .moderate
        default: .hard
        }
    }

    static func zone(hr: Int) -> Int {
        switch Double(hr) / assumedMaxHR {
        case ..<0.6: 1
        case ..<0.7: 2
        case ..<0.8: 3
        case ..<0.9: 4
        default: 5
        }
    }
}
