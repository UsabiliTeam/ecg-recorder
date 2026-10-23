import XCTest
@testable import ECGRecorder

final class FormatTests: XCTestCase {
    func testCSVEscapeRoundTrip() {
        let tricky = ["plain", "a,b", "say \"hi\"", "multi\nline"]
        let line = tricky.map(CSVFormat.escape).joined(separator: ",")
        XCTAssertEqual(CSVFormat.split(line[...]), ["plain", "a,b", "say \"hi\"", "multi\nline"].map { $0 })
    }

    func testRowHasAllColumns() {
        let formatter = RowFormatter()
        let line = formatter.line(prefix: "P01,A1B2C3D4,", stream: .ecg, unix: 1_700_000_000.123456,
                                  sensorNs: 123, RowFields(ecg: -250))
        let fields = CSVFormat.split(line.dropLast()[...])
        XCTAssertEqual(fields.count, CSVFormat.columns.count)
        XCTAssertEqual(fields[CSVFormat.column("stream")], "ECG")
        XCTAssertEqual(fields[CSVFormat.column("value")], "-250")
        XCTAssertEqual(fields[CSVFormat.column("sensor_time_ns")], "123")
    }

    func testFileNameSanitizesTag() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let name = Session.fileName(start: start, tag: "Run / 5k?")
        XCTAssertTrue(name.hasPrefix("ECGRecorder_"))
        XCTAssertTrue(name.hasSuffix("_Run---5k-.csv"))
        XCTAssertFalse(name.contains("/"))
    }

    func testValidation() {
        XCTAssertNil(Validation.clean("   ", max: 10))
        XCTAssertEqual(Validation.clean("  abcdef ", max: 3), "abc")
        XCTAssertEqual(Validation.deviceID(" a1b2c3d4 "), "A1B2C3D4")
        XCTAssertNil(Validation.deviceID("XYZ"))
        XCTAssertNil(Validation.deviceID("A1B2C3D4E"))
    }

    func testValidationBlocksSpreadsheetFormulasAndLineBreaks() {
        XCTAssertEqual(Validation.clean("=HYPERLINK(\"x\")", max: 40), "HYPERLINK(\"x\")")
        XCTAssertEqual(Validation.clean(" +-@P1", max: 40), "P1")
        XCTAssertEqual(Validation.clean("a\nb\tc", max: 40), "abc")
        XCTAssertEqual(Validation.clean("Run 5-k", max: 40), "Run 5-k")
        XCTAssertNil(Validation.clean("==", max: 40))
    }

    func testFieldReadsOneColumnWithoutSplitting() {
        XCTAssertEqual(CSVFormat.field(2, of: "P01,DEV,ECG,1.0,5,1 2 3,,9"), "ECG")
        XCTAssertEqual(CSVFormat.field(2, of: "\"a,ECG,b\",DEV,SYNC,1.0"), "SYNC")
        XCTAssertEqual(CSVFormat.field(1, of: "a,b"), "b")
        XCTAssertNil(CSVFormat.field(3, of: "a,b"))
    }

    func testSessionInfoReadsKeysBeforeTheTag() {
        let info = SessionInfo("session_info;schema=2;rmssd_window_s=120;tag=x;rmssd_window_s=9")
        XCTAssertEqual(info.value("rmssd_window_s"), "120")
        XCTAssertEqual(info.tag, "x;rmssd_window_s=9")
    }

    private func ntpReply(_ request: Data, serverUnix: Double, mode: UInt8 = 4, stratum: UInt8 = 2) -> Data {
        var packet = Data(count: 48)
        packet[0] = 0x20 | mode                            // LI 0, version 4
        packet[1] = stratum
        packet.replaceSubrange(24..<32, with: request[40..<48])
        let stamp = NTPClient.request(sentAt: serverUnix)[40..<48]
        packet.replaceSubrange(32..<40, with: stamp)
        packet.replaceSubrange(40..<48, with: stamp)
        return packet
    }

    func testNTPParsing() throws {
        // Server 2.0 s ahead of the phone, symmetric zero latency.
        let t1 = 1_700_000_000.25
        let request = NTPClient.request(sentAt: t1)
        let offset = NTPClient.parse(ntpReply(request, serverUnix: t1 + 2), sentAt: t1, receivedAt: t1)
        XCTAssertEqual(try XCTUnwrap(offset), 2.0, accuracy: 1e-6)
        XCTAssertNil(NTPClient.parse(Data(count: 10), sentAt: 0, receivedAt: 0))
    }

    func testNTPRejectsRepliesThatDoNotAnswerOurRequest() {
        let t1 = 1_700_000_000.25
        let other = NTPClient.request(sentAt: t1 - 5)
        XCTAssertNil(NTPClient.parse(ntpReply(other, serverUnix: t1 + 2), sentAt: t1, receivedAt: t1), "spoofed or stale")
        let request = NTPClient.request(sentAt: t1)
        XCTAssertNil(NTPClient.parse(ntpReply(request, serverUnix: t1, stratum: 0), sentAt: t1, receivedAt: t1), "kiss-of-death")
        XCTAssertNil(NTPClient.parse(ntpReply(request, serverUnix: t1, mode: 3), sentAt: t1, receivedAt: t1), "not a server reply")
    }

    func testOutdatedIndexIsDropped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionIndexStore(directory: dir)
        try store.save(Session(id: UUID(), start: .now, duration: 1, tag: "", participants: [], fileName: "x.csv"), traces: [:])
        store.purgeIfOutdated()
        XCTAssertTrue(store.loadSessions().isEmpty, "entries from older calculations are rebuilt")
        try store.save(Session(id: UUID(), start: .now, duration: 1, tag: "", participants: [], fileName: "x.csv"), traces: [:])
        store.purgeIfOutdated()
        XCTAssertEqual(store.loadSessions().count, 1, "a current index is kept")
    }
}

@MainActor
final class RosterTests: XCTestCase {
    func testAddAndRejectDuplicates() throws {
        let roster = Roster(url: nil)
        try roster.addParticipant("P01")
        XCTAssertThrowsError(try roster.addParticipant("P01"))
        XCTAssertThrowsError(try roster.addParticipant("  "))
        try roster.addDevice("a1b2c3d4")
        XCTAssertThrowsError(try roster.addDevice("A1B2C3D4"))
        XCTAssertEqual(roster.devices, ["A1B2C3D4"])
    }

    func testRemovingParticipantKeepsNamesInSessions() throws {
        let roster = Roster(url: nil)
        let p = try roster.addParticipant("P01")
        let session = Session(id: UUID(), start: .now, duration: 60, tag: "", participants: ["P01"], fileName: "x.csv")
        roster.removeParticipant(p.id)
        XCTAssertNil(roster.participant(p.id))
        XCTAssertEqual(session.participants, ["P01"])
    }
}

#if canImport(UIKit)
@MainActor
final class SettingsTests: XCTestCase {
    /// Settings saved before Notifications existed keep their values; the new ones start at their defaults.
    func testOlderSettingsStillDecode() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "settings-\(UUID().uuidString)"))
        let old = #"{"rmssdWindow":120,"alertChannels":["Sound"],"zonesEnabled":true,"maxHRMethod":"None","useSimulator":true}"#
        defaults.set(Data(old.utf8), forKey: "settings.v1")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.rmssdWindow, 120)
        XCTAssertEqual(settings.alertChannels, [.sound])
        XCTAssertTrue(settings.useSimulator)
        XCTAssertEqual(settings.endSound, EndSound.bell)
        XCTAssertTrue(AlertEvent.allCases.allSatisfy(settings.alerts))

        settings.mutedEvents = [.storage]
        settings.endSound = EndSound.silent
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.alerts(.storage))
        XCTAssertEqual(reloaded.endSound, EndSound.silent)
        XCTAssertEqual(EndSound.options.first?.id, EndSound.bell)
        XCTAssertEqual(EndSound.name(of: "../../etc/passwd"), "Bell")
    }
}
#endif
