import XCTest
@testable import ECGRecorder

/// Polls until `condition` holds instead of sleeping a fixed time.
func waitUntil(timeout: Double = 10, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while await !condition() {
        if Date() > deadline { XCTFail("timed out waiting for condition"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

final class RecordingTests: XCTestCase {
    private func temp(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(name) }

    /// End to end with simulated devices: rows reach the file, the metrics are written, and the index can be rebuilt.
    func testEngineRecordsAndIndexRebuilds() async throws {
        let members = [EngineMember(slotID: UUID(), participant: "P01", deviceID: "A1B2C3D4"),
                       EngineMember(slotID: UUID(), participant: "P02", deviceID: "E5F6A7B8")]
        let engine = SessionEngine(members: members, provider: SimulatedProvider(),
                                   config: EngineConfig(rmssdWindow: 60, accRate: 50, accRange: 8, zonesEnabled: false))
        await engine.begin()
        try await waitUntil {
            for m in members where await engine.snapshot(of: m.slotID)?.link != .streaming { return false }
            return true
        }

        let url = temp("ECGRecorder_test_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.startRecording(id: UUID(), tag: "test, tag", start: .now, url: url, resume: false, ntpOffset: 0.012,
                                       names: Dictionary(uniqueKeysWithValues: members.map { ($0.slotID, $0.participant) }))
        try await Task.sleep(for: .seconds(2.5))   // real time: the simulated strap produces data at 130 Hz
        let finished = try await engine.stopRecording(ntpOffset: nil)
        await engine.shutdown()

        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = text.split(separator: "\n")
        XCTAssertEqual(String(rows[0]) + "\n", CSVFormat.header)
        for stream in ["ECG", "HR", "RR", "SYNC"] {
            XCTAssertTrue(text.contains(",\(stream),"), "missing \(stream) rows")
        }
        XCTAssertEqual(finished.session.participants, ["P01", "P02"])
        // Every row has the full column set, even with a comma in the tag.
        for row in rows.dropFirst() { XCTAssertEqual(CSVFormat.split(row).count, CSVFormat.columns.count) }
        // Two devices for about 2.5 s at 130 Hz; allow slack for start-up and packet boundaries.
        let ecgSamples = rows.map { CSVFormat.split($0) }.filter { $0[CSVFormat.column("stream")] == "ECG" }
            .reduce(0) { $0 + $1[CSVFormat.column("value")].split(separator: " ").count }
        XCTAssertGreaterThan(ecgSamples, 2 * 1 * 130)

        let rebuilt = await IndexRebuilder.rebuild(csv: url)
        XCTAssertEqual(rebuilt?.0.id, finished.session.id)
        XCTAssertEqual(rebuilt?.0.tag, "test, tag")
        XCTAssertEqual(Set(rebuilt?.0.participants ?? []), ["P01", "P02"])
    }

    func testImplausibleRRIsFlaggedNotDropped() async throws {
        let formatter = RowFormatter()
        let line = formatter.line(prefix: "P01,A1B2C3D4,", stream: .rr, unix: 1, sensorNs: nil,
                                  RowFields(rr: 150, flag: RRQuality.flag(rr: 150, contact: true)))
        XCTAssertTrue(line.contains("implausible_rr"))
    }

    /// Files recorded before schema 2 (23 columns) must still rebuild.
    func testIndexRebuildsFromLegacyFile() async throws {
        let id = UUID()
        let header = "session_id,tag,participant,device_id,stream,unix_time_s,local_time,mono_time_s,sensor_time_ns,ecg_uv,acc_x,acc_y,acc_z,hr_bpm,rr_ms,contact,battery_pct,rmssd_ms,rmssd_window_s,hr_zone,event,flag,ntp_offset_s"
        let rows = ["\(id),t1,R,DEV,SYNC,1000.0,x,1,,,,,,,,,,,,,session_start,,",
                    "\(id),t1,R,DEV,HR,1001.0,x,1,,,,,,60,,1,,,,,,,",
                    "\(id),t1,R,DEV,RR,1001.0,x,1,,,,,,,900.0,,,,,,,,",
                    "\(id),t1,R,DEV,SYNC,1010.0,x,1,,,,,,,,,,,,,session_stop,,"]
        let url = temp("legacy_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try ([header] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let rebuilt = await IndexRebuilder.rebuild(csv: url)
        XCTAssertEqual(rebuilt?.0.id, id)
        XCTAssertEqual(rebuilt?.0.tag, "t1")
        XCTAssertEqual(rebuilt?.0.duration ?? 0, 10, accuracy: 0.01)
    }
}
