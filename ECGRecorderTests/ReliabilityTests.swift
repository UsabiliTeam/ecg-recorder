import XCTest
@testable import ECGRecorder

/// Sensor that sends exactly the events a test gives it, so expected file contents are known in advance.
final class ScriptedSensor: Sensor, @unchecked Sendable {
    let events: AsyncStream<SensorEvent>
    private let continuation: AsyncStream<SensorEvent>.Continuation

    init() {
        var c: AsyncStream<SensorEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    func connect() { continuation.yield(.link(.streaming)) }
    func disconnect() {}
    func send(_ event: SensorEvent) { continuation.yield(event) }
}

final class ScriptedProvider: SensorProvider, @unchecked Sendable {
    let sensor = ScriptedSensor()
    func makeSensor(deviceID: String, config: StreamConfig) -> Sensor { sensor }
    func scan() -> AsyncStream<String> { AsyncStream { $0.finish() } }
}

/// Data completeness and calculation accuracy from device to CSV, checked against known inputs.
final class ReliabilityTests: XCTestCase {
    private struct Row {
        let fields: [String]
        subscript(_ name: String) -> String { fields[CSVFormat.column(name)] }
    }

    /// Records the events the script sends and returns the parsed rows.
    private func record(_ script: (ScriptedSensor) async throws -> Void) async throws -> [Row] {
        let provider = ScriptedProvider()
        let member = EngineMember(slotID: UUID(), participant: "P01", deviceID: "A1B2C3D4")
        let engine = SessionEngine(members: [member], provider: provider,
                                   config: EngineConfig(rmssdWindow: 60, accRate: 50, accRange: 8, zonesEnabled: false))
        await engine.begin()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reliability_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.startRecording(id: UUID(), tag: "", start: .now, url: url, resume: false, ntpOffset: nil,
                                        names: [member.slotID: "P01"])
        try await script(provider.sensor)
        // Events are handled in order, so once this sentinel shows, everything sent before it is in the file.
        provider.sensor.send(.battery(99, .now()))
        try await waitUntil { await engine.snapshot(of: member.slotID)?.battery == 99 }
        _ = try await engine.stopRecording(ntpOffset: nil)
        await engine.shutdown()
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").dropFirst().map { Row(fields: CSVFormat.split($0)) }
    }

    private func heart(_ rr: [Int]) -> SensorEvent {
        .heart(HeartSample(bpm: 75, rrMs: rr.map(Double.init), contact: true), .now())
    }

    // MARK: Completeness

    func testEveryEcgSampleReachesTheFileInOrderWithoutGaps() async throws {
        let step: UInt64 = 7_692_308                      // 130 Hz
        let base: UInt64 = 1_000_000_000_000
        let packets = 5, perPacket = 73                   // what an H10 sends
        let rows = try await record { sensor in
            for p in 0..<packets {
                let samples = (0..<perPacket).map { i -> EcgSample in
                    let n = p * perPacket + i
                    return EcgSample(sensorNs: base + UInt64(n) * step, microvolts: Int32(n))
                }
                // Each packet arrives when its last sample was taken, as it would over Bluetooth.
                let arrival = Stamp(mono: 100 + Double(p + 1) * Double(perPacket) / 130,
                                    unix: 1_800_000_000 + Double(p + 1) * Double(perPacket) / 130)
                sensor.send(.ecg(samples, arrival))
            }
        }
        let ecg = rows.filter { $0["stream"] == "ECG" }
        XCTAssertEqual(ecg.count, packets, "one row per packet")
        let values = ecg.flatMap { $0["value"].split(separator: " ").compactMap { Int($0) } }
        XCTAssertEqual(values, Array(0..<(packets * perPacket)), "samples dropped, reordered or altered")
        for row in ecg {
            let n = UInt64(row["value"].split(separator: " ").count - 1)
            let first = try XCTUnwrap(UInt64(row["sensor_time_ns"])), last = try XCTUnwrap(UInt64(row["note"]))
            XCTAssertEqual((last - first) / n, step, "sample spacing inside a packet")
        }
        let starts = ecg.compactMap { UInt64($0["sensor_time_ns"]) }
        XCTAssertEqual(Set(zip(starts.dropFirst(), starts).map { $0 - $1 }), [step * UInt64(perPacket)],
                       "gap between packets")
        let unix = ecg.compactMap { Double($0["unix_time_s"]) }
        XCTAssertEqual(unix, unix.sorted(), "phone timestamps go backwards")
    }

    func testDisconnectAndReconnectAreLogged() async throws {
        let rows = try await record { sensor in
            sensor.send(.link(.disconnected))
            sensor.send(.link(.streaming))
        }
        XCTAssertEqual(rows.filter { $0["stream"] == "EVENT" }.map { $0["note"] }, ["disconnect", "reconnect"])
    }

    func testEveryRowHasTheFullColumnSet() async throws {
        let rows = try await record { $0.send(self.heart([800, 810])) }
        XCTAssertFalse(rows.isEmpty)
        for row in rows { XCTAssertEqual(row.fields.count, CSVFormat.columns.count) }
    }

    // MARK: Accuracy

    func testRRInTheFileGivesHandCalculatedRMSSD() async throws {
        // Differences 10, -20, 15, -10, 25 -> mean square 290 -> RMSSD 17.029 ms.
        let rows = try await record { sensor in
            for rr in [800, 810, 790, 805, 795, 820] { sensor.send(self.heart([rr])) }
        }
        // RMSSD is not stored; it is recomputed from the recorded RR intervals.
        let rr = rows.filter { $0["stream"] == "RR" }.compactMap { Double($0["value"]) }
        XCTAssertEqual(rr.count, 6)
        XCTAssertEqual(try XCTUnwrap(RMSSD().value(rr: rr)), 290.0.squareRoot(), accuracy: 0.01)
    }

    func testImplausibleIntervalIsKeptFlaggedAndExcludedFromMetrics() async throws {
        let rows = try await record { sensor in
            for rr in [800, 810, 150, 790, 805, 795, 820] { sensor.send(self.heart([rr])) }
        }
        let rr = rows.filter { $0["stream"] == "RR" }
        XCTAssertEqual(rr.count, 7, "flagged interval must stay in the file")
        XCTAssertEqual(rr.filter { $0["flag"] == "implausible_rr" }.map { $0["value"] }, ["150.0"])
        // Excluding flagged beats leaves the six clean beats for the offline calculation.
        let clean = rr.filter { $0["flag"].isEmpty }.compactMap { Double($0["value"]) }
        XCTAssertEqual(clean, [800, 810, 790, 805, 795, 820])
    }

    func testEctopicBeatStaysRawInTheFileAndIsExcludedFromTheSavedRMSSD() async throws {
        // Breathing-like rhythm with one premature beat and its compensatory pause.
        var beats = (0..<60).map { Int(850 + 40 * sin(Double($0) / 3)) }
        beats[30] = beats[30] * 6 / 10; beats[31] = beats[31] * 14 / 10
        let provider = ScriptedProvider()
        let member = EngineMember(slotID: UUID(), participant: "P01", deviceID: "A1B2C3D4")
        let engine = SessionEngine(members: [member], provider: provider,
                                   config: EngineConfig(rmssdWindow: 60, accRate: 50, accRange: 8, zonesEnabled: false))
        await engine.begin()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ectopic_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.startRecording(id: UUID(), tag: "e", start: .now, url: url, resume: false, ntpOffset: nil,
                                        names: [member.slotID: "P01"])
        var clock = 1_800_000_000.0
        for rr in beats {
            clock += Double(rr) / 1000
            provider.sensor.send(.heart(HeartSample(bpm: 70, rrMs: [Double(rr)], contact: true), Stamp(mono: clock, unix: clock)))
        }
        provider.sensor.send(.battery(99, .now()))
        try await waitUntil { await engine.snapshot(of: member.slotID)?.battery == 99 }
        let saved = try await engine.stopRecording(ntpOffset: nil)
        await engine.shutdown()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let rr = lines.map { CSVFormat.split($0) }.filter { $0[CSVFormat.column("stream")] == "RR" }
        XCTAssertEqual(rr.count, beats.count, "every interval stays in the file")
        XCTAssertTrue(rr.allSatisfy { $0[CSVFormat.column("flag")].isEmpty }, "artifacts are computed, not written")
        XCTAssertTrue(try XCTUnwrap(lines.first { $0.contains("session_stop") }).hasSuffix("rr_flagged=2;rr_ectopic=2"))
        let clean = beats.enumerated().filter { $0.offset != 30 && $0.offset != 31 }.map { Double($0.element) }
        var expected = NNSummary()
        for (i, x) in beats.enumerated() { expected.add(rr: Double(x), flag: i == 30 || i == 31 ? "ectopic" : nil) }
        XCTAssertEqual(try XCTUnwrap(saved.session.avgRMSSD), try XCTUnwrap(expected.rmssd), accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(saved.session.avgRMSSD), try XCTUnwrap(RMSSD().value(rr: clean)) + 5)
    }

    func testPredictedRMSSDSurvivesIndexRebuild() async throws {
        let member = EngineMember(slotID: UUID(), participant: "P01", deviceID: "A1B2C3D4")
        let provider = ScriptedProvider()
        let engine = SessionEngine(members: [member], provider: provider,
                                   config: EngineConfig(rmssdWindow: 60, accRate: 50, accRange: 8, zonesEnabled: false))
        await engine.begin()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prediction_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        // A tag that looks like a key must not be read as one.
        try await engine.startRecording(id: UUID(), tag: "x;predicted_rmssd_ms=9", start: .now, url: url, resume: false,
                                        ntpOffset: nil, names: [member.slotID: "P01"], predictedRMSSD: 45)
        for rr in [800, 810, 790] { provider.sensor.send(heart([rr])) }
        provider.sensor.send(.battery(99, .now()))
        try await waitUntil { await engine.snapshot(of: member.slotID)?.battery == 99 }
        let finished = try await engine.stopRecording(ntpOffset: nil)
        await engine.shutdown()
        XCTAssertEqual(finished.session.predictedRMSSD, 45)
        let result = await IndexRebuilder.rebuild(csv: url)
        let rebuilt = try XCTUnwrap(result).0
        XCTAssertEqual(rebuilt.predictedRMSSD, 45)
        XCTAssertEqual(rebuilt.tag, "x;predicted_rmssd_ms=9")
    }

    func testMarkersAreWrittenAndSurviveIndexRebuild() async throws {
        let member = EngineMember(slotID: UUID(), participant: "P01", deviceID: "A1B2C3D4")
        let provider = ScriptedProvider()
        let engine = SessionEngine(members: [member], provider: provider,
                                   config: EngineConfig(rmssdWindow: 60, accRate: 50, accRange: 8, zonesEnabled: false))
        await engine.begin()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markers_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        await engine.mark("too early", at: .now())               // before the file exists: ignored
        try await engine.startRecording(id: UUID(), tag: "m", start: .now, url: url, resume: false,
                                        ntpOffset: nil, names: [member.slotID: "P01"])
        await engine.mark(EventMarker.defaultName(1), at: Stamp(mono: 1, unix: 1_800_000_000.1234))
        await engine.mark("run, fast", at: Stamp(mono: 2, unix: 1_800_000_060.5))
        provider.sensor.send(heart([800]))
        let finished = try await engine.stopRecording(ntpOffset: nil)
        await engine.shutdown()

        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst()
            .map { CSVFormat.split($0) }.filter { $0[CSVFormat.column("stream")] == "MARKER" }
        XCTAssertEqual(rows.map { $0[CSVFormat.column("note")] }, ["event01", "run, fast"])
        XCTAssertEqual(rows.first?[CSVFormat.column("unix_time_s")], "1800000000.123")
        let expected = [EventMarker(t: 1_800_000_000.123, name: "event01"), EventMarker(t: 1_800_000_060.5, name: "run, fast")]
        XCTAssertEqual(finished.session.markers, expected)
        let result = await IndexRebuilder.rebuild(csv: url)
        XCTAssertEqual(try XCTUnwrap(result).0.markers, expected)
    }

    func testPredictionSummaryShowsBothNumbersOnly() {
        func session(_ guess: Int?, _ actual: Double?) -> Session {
            Session(id: UUID(), start: .now, duration: 60, tag: "", participants: ["P01"], fileName: "",
                    avgRMSSD: actual, predictedRMSSD: guess)
        }
        XCTAssertEqual(Format.predictionSummary(session(50, 52.4)), "Predicted RMSSD: 50 ms\nRecorded RMSSD: 52 ms")
        XCTAssertEqual(Format.predictionSummary(session(50, nil)), "Predicted RMSSD: 50 ms\nRecorded RMSSD: –")
        XCTAssertNil(Format.predictionSummary(session(nil, 52)))
    }

    func testNoContactBeatsAreFlaggedAndExcluded() async throws {
        let rows = try await record { sensor in
            sensor.send(.heart(HeartSample(bpm: 70, rrMs: [850.0], contact: false), .now()))
        }
        XCTAssertEqual(rows.filter { $0["stream"] == "RR" }.first?["flag"], "no_contact")
        XCTAssertEqual(rows.filter { $0["stream"] == "CONTACT" }.map { $0["value"] }, ["0"])
    }

    func testContactIsWrittenOnlyWhenItChanges() async throws {
        let rows = try await record { sensor in
            for _ in 0..<5 { sensor.send(self.heart([800])) }
            sensor.send(.heart(HeartSample(bpm: 70, rrMs: [800.0], contact: false), .now()))
        }
        XCTAssertEqual(rows.filter { $0["stream"] == "CONTACT" }.map { $0["value"] }, ["1", "0"])
    }

    func testEcgBytesPerSampleStaySmall() {
        let packet = (0..<73).map { Int32(($0 * 37) % 400 - 100) }
        let line = RowFormatter().line(prefix: "P01,A1B2C3D4,", stream: .ecg, unix: 1_790_019_757.758536,
                                       sensorNs: 599_620_770_430_708_864,
                                       RowFields(ecgPacket: packet, event: "599620770992636800"))
        XCTAssertLessThanOrEqual(line.utf8.count / 73, 8)
    }

    /// The rolling window must match a naive re-computation over the same beats, whatever the sequence.
    func testPipelineMatchesNaiveReferenceOnRandomData() throws {
        var generator = SystemRandomNumberGenerator()
        var pipeline = MetricPipeline(windowSeconds: 30)
        var beats: [(rr: Double, normal: Bool)] = []
        for _ in 0..<600 {
            let rr = Double.random(in: 500...1200, using: &generator)
            let normal = Double.random(in: 0...1, using: &generator) > 0.1
            beats.append((rr, normal))
            // Naive window: the newest beats whose total stays within 30 s (always at least one).
            var window = beats
            while window.map(\.rr).reduce(0, +) / 1000 > 30, window.count > 1 { window.removeFirst() }
            let nn = window.filter(\.normal).map(\.rr)
            var diffs: [Double] = []
            for i in window.indices.dropFirst() where window[i].normal && window[i - 1].normal {
                diffs.append(window[i].rr - window[i - 1].rr)
            }
            let out = pipeline.add(rr: rr, normal: normal)
            guard nn.reduce(0, +) / 1000 >= pipeline.minimumSeconds else {
                XCTAssertTrue(out.isEmpty, "reported before the window holds enough clean data")
                continue
            }
            for metric in MetricPipeline.standard {
                let expected = try XCTUnwrap(metric.value(NNWindow(nn: nn, diffs: diffs)))
                XCTAssertEqual(try XCTUnwrap(out[metric.name]), expected, accuracy: 1e-9)
            }
        }
    }

    /// The index saved at the end of a recording must be exactly what a rebuild from the CSV produces:
    /// same flags, gaps, window (a non-default one, read back from the file) and totals.
    func testSavedIndexEqualsIndexRebuiltFromTheFile() async throws {
        let provider = ScriptedProvider()
        let member = EngineMember(slotID: UUID(), participant: "P01", deviceID: "A1B2C3D4")
        let engine = SessionEngine(members: [member], provider: provider,
                                   config: EngineConfig(rmssdWindow: 120, accRate: 50, accRange: 8, zonesEnabled: false))
        await engine.begin()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("consistency_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.startRecording(id: UUID(), tag: "c", start: .now, url: url, resume: false, ntpOffset: nil,
                                        names: [member.slotID: "P01"])
        var clock = 1_800_000_000.0
        func beats(_ count: Int, contact: Bool = true) {
            for i in 0..<count {
                // Full-resolution H10 values (1/1024 s), breathing-like variation, one premature beat pair.
                var rr = 850 + 40 * sin(Double(i) / 3)
                if i == 50 { rr *= 0.6 } else if i == 51 { rr *= 1.4 }
                clock += rr / 1000
                let exact = (rr * 1.024).rounded() / 1.024
                provider.sensor.send(.heart(HeartSample(bpm: 70, rrMs: [exact], contact: contact),
                                            Stamp(mono: clock, unix: clock)))
            }
        }
        beats(150)
        provider.sensor.send(.link(.disconnected))
        provider.sensor.send(.link(.streaming))
        beats(5, contact: false)
        beats(100)
        clock += 20                                      // silent Bluetooth: beats lost without a link event
        beats(80)
        provider.sensor.send(.battery(99, .now()))
        try await waitUntil { await engine.snapshot(of: member.slotID)?.battery == 99 }
        let saved = try await engine.stopRecording(ntpOffset: nil)
        await engine.shutdown()

        let result = await IndexRebuilder.rebuild(csv: url)
        let (rebuilt, traces) = try XCTUnwrap(result)
        XCTAssertEqual(try XCTUnwrap(rebuilt.avgRMSSD), try XCTUnwrap(saved.session.avgRMSSD), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rebuilt.avgHR), try XCTUnwrap(saved.session.avgHR), accuracy: 1e-9)
        let live = try XCTUnwrap(saved.traces["P01"]), fromFile = try XCTUnwrap(traces["P01"])
        XCTAssertEqual(live.count, fromFile.count)
        XCTAssertGreaterThan(live.count, 40)
        XCTAssertTrue(live.contains { $0.rmssd == nil } && live.contains { $0.rmssd != nil }, "gaps show as gaps")
        for (a, b) in zip(live, fromFile) {
            XCTAssertEqual(a.t, b.t, accuracy: 1e-6)
            XCTAssertEqual(a.hr, b.hr)
            XCTAssertEqual(a.rmssd == nil, b.rmssd == nil)
            if let x = a.rmssd, let y = b.rmssd { XCTAssertEqual(x, y, accuracy: 1e-9) }
            if let x = a.sdnn, let y = b.sdnn { XCTAssertEqual(x, y, accuracy: 1e-9) }
        }
        let stop = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.contains("session_stop") }
        XCTAssertTrue(try XCTUnwrap(stop).contains("rr_count=335;rr_flagged=11;rr_ectopic=6;rr_no_contact=5"), "3 × 2 ectopic + 5 no-contact: \(stop ?? "")")
    }

    func testResumeCutsATornLastRow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("torn_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try (CSVFormat.header + "P01,A1B2C3D4,HR,1.000,,70,,\nP01,A1B2C3D4,ECG,2.000,5,12 34 5").write(to: url, atomically: true, encoding: .utf8)
        let writer = try CSVSessionWriter(url: url, resume: true)
        try writer.append("P01,A1B2C3D4,HR,3.000,,71,,\n")
        try writer.close()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.last, "P01,A1B2C3D4,HR,3.000,,71,,")
    }

    func testMetricsOnConstantHeartbeatAreZero() throws {
        let rr = [Double](repeating: 900, count: 20)
        XCTAssertEqual(try XCTUnwrap(RMSSD().value(rr: rr)), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(SDNN().value(rr: rr)), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(PNN50().value(rr: rr)), 0, accuracy: 1e-12)
    }
}
