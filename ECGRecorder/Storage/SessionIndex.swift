import Foundation

/// Pre-computed traces per session so the View tab never parses multi-GB CSVs.
/// Derived data: `IndexRebuilder` can recreate everything from the CSVs.
struct SessionIndexStore: Sendable {
    /// Bump when the metric calculations change: an outdated index is dropped and rebuilt from the CSVs,
    /// so old recordings show numbers from the current code.
    static let version = 3

    let directory: URL

    init(directory: URL = AppPaths.indexDirectory) { self.directory = directory }

    private func metaURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).meta.json") }
    private func tracesURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).traces.json") }
    private var versionURL: URL { directory.appendingPathComponent("version") }

    /// Empties the index when it was built by an older version of the calculations.
    func purgeIfOutdated() {
        let current = String(Self.version)
        guard (try? String(contentsOf: versionURL, encoding: .utf8)) != current else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
        try? Data(current.utf8).write(to: versionURL, options: .atomic)
    }

    func save(_ session: Session, traces: [String: [IndexPoint]]) throws {
        try JSONFile.write(traces, to: tracesURL(session.id))
        try JSONFile.write(session, to: metaURL(session.id))
    }

    func loadSessions() -> [Session] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".meta.json") }
            .compactMap { JSONFile.read(Session.self, from: $0) }
    }

    func traces(for id: UUID) -> [String: [IndexPoint]] {
        JSONFile.read([String: [IndexPoint]].self, from: tracesURL(id)) ?? [:]
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: metaURL(id))
        try? FileManager.default.removeItem(at: tracesURL(id))
    }
}

/// Recreates a session's index entry by streaming its CSV. ECG and ACC rows are skipped without parsing.
/// Feeds `RecordingAnalysis` exactly what the engine fed it while recording (RR values, flags, arrival times,
/// link-loss events), so a rebuilt entry matches the one saved at the end of the recording.
enum IndexRebuilder {
    static func rebuild(csv url: URL) async -> (Session, [String: [IndexPoint]])? {
        var id: UUID?
        var tag = ""
        var predicted: Int?
        var window = 60
        var start: Double?
        var end: Double?
        var names: [String] = []
        var markers: [EventMarker] = []
        var analyzers: [String: RecordingAnalysis] = [:]
        var hr: [String: Int] = [:]
        var col: [String: Int] = [:]          // header decides the schema: old files (v1) still load
        var legacy = false

        do {
            var first = true
            for try await line in url.lines {
                if first {
                    first = false
                    let header = CSVFormat.split(line[...])
                    col = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                    legacy = col["session_id"] != nil
                    continue
                }
                guard let cStream = col["stream"], let cUnix = col["unix_time_s"] else { return nil }
                if let stream = CSVFormat.field(cStream, of: line), stream == "ECG" || stream == "ACC" { continue }
                let f = CSVFormat.split(line[...])
                guard f.count == col.count, let t = Double(f[cUnix]) else { continue }
                let name = f[col["participant"]!]
                let note = f[col[legacy ? "event" : "note"]!]
                if legacy, id == nil { id = UUID(uuidString: f[0]); tag = f[1] }
                if !name.isEmpty, !names.contains(name) { names.append(name) }
                end = t
                switch f[cStream] {
                case "SYNC":
                    if note.hasPrefix("session_info;"), id == nil {
                        let info = SessionInfo(note)
                        id = info.value("id").flatMap(UUID.init(uuidString:))
                        tag = info.tag
                        predicted = info.value("predicted_rmssd_ms").flatMap { Int($0) }
                        window = info.value("rmssd_window_s").flatMap { Int($0) } ?? window
                    }
                    if note == "session_start", start == nil { start = t }
                    if note == "session_resume" { analyzers[name]?.gap() }
                case "HR":
                    if let v = Double(f[col[legacy ? "hr_bpm" : "value"]!]) { hr[name] = Int(v) }
                case "RR":
                    guard let rr = Double(f[col[legacy ? "rr_ms" : "value"]!]) else { continue }
                    // Only the device's own flags count; files from before 2026-09-29 also carry `ectopic`, which
                    // artifact detection now recomputes.
                    let flag = f[col["flag"]!]
                    var analyzer = analyzers[name] ?? RecordingAnalysis(windowSeconds: window)
                    analyzer.add(rr: rr, deviceFlag: RRQuality.deviceFlags.contains(flag) ? flag : nil, at: t, hr: hr[name])
                    analyzers[name] = analyzer
                case "MARKER":
                    markers.append(EventMarker(t: t, name: note))
                case "EVENT":
                    if note == "disconnect" || note == "no_data" { analyzers[name]?.gap() }
                default: break
                }
            }
        } catch { return nil }

        guard let id, let start, let end else { return nil }
        let results = analyzers.mapValues { $0.finish() }
        let traces = results.mapValues(\.trace)
        // Only meaningful for a single participant; a multi-participant session has no one "session average".
        let solo = names.count == 1 ? names.first.flatMap { results[$0]?.summary } : nil
        let session = Session(id: id, start: Date(timeIntervalSince1970: start), duration: max(0, end - start),
                              tag: tag, participants: names, fileName: url.lastPathComponent,
                              avgHR: solo?.meanHR, avgRMSSD: solo?.rmssd, predictedRMSSD: predicted,
                              markers: markers.isEmpty ? nil : markers)
        return (session, traces)
    }
}

/// The `session_info` note: `session_info;key=value;...;tag=<free text>`. Keys are read only from before the tag,
/// which may itself contain "key=" text.
struct SessionInfo {
    let tag: String
    private let keys: [String: String]

    init(_ note: String) {
        let head: Substring
        if let r = note.range(of: ";tag=") {
            tag = String(note[r.upperBound...])
            head = note[..<r.lowerBound]
        } else {
            tag = ""
            head = note[...]
        }
        var keys: [String: String] = [:]
        for part in head.split(separator: ";") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            keys[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        self.keys = keys
    }

    func value(_ key: String) -> String? { keys[key] }
}

/// Marker for a recording in progress, so an iOS relaunch can resume appending to the same file.
struct ActiveRecording: Codable {
    struct Member: Codable { let participant: String; let deviceID: String }
    let id: UUID
    let start: Date
    let tag: String
    let fileName: String
    let members: [Member]
    /// Optional so markers written by older versions still decode.
    var predictedRMSSD: Int?
}

enum ActiveRecordingStore {
    static func save(_ record: ActiveRecording) { try? JSONFile.write(record, to: AppPaths.activeRecordingFile) }
    static func load() -> ActiveRecording? { JSONFile.read(ActiveRecording.self, from: AppPaths.activeRecordingFile) }
    static func clear() { try? FileManager.default.removeItem(at: AppPaths.activeRecordingFile) }
}
