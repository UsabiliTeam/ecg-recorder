import XCTest
@testable import ECGRecorder

final class AdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func slot(_ state: LinkState, waited: TimeInterval? = nil, device: String? = "ABCD1234", battery: Int? = nil) -> Slot {
        var s = Slot(participantID: UUID(), deviceID: device)
        s.state = state
        s.battery = battery
        s.waitingSince = waited.map { now.addingTimeInterval(-$0) }
        return s
    }

    func testBluetoothStatesBlockOrStayQuiet() {
        XCTAssertNil(ConnectionAdvisor.phone(.ready))
        XCTAssertNil(ConnectionAdvisor.phone(.unknown))
        XCTAssertEqual(ConnectionAdvisor.phone(.poweredOff)?.severity, .blocking)
        XCTAssertEqual(ConnectionAdvisor.phone(.unauthorized)?.fix, .openSettings)
        XCTAssertEqual(ConnectionAdvisor.phone(.resetting)?.severity, .warning)
    }

    func testDeviceAdviceWaitsForGracePeriod() {
        XCTAssertNil(ConnectionAdvisor.device(slot(.connecting, waited: 3), now: now))
        XCTAssertEqual(ConnectionAdvisor.device(slot(.connecting, waited: 20), now: now)?.title, "Can't reach device 1234")
        XCTAssertEqual(ConnectionAdvisor.device(slot(.connected, waited: 20), now: now)?.title, "Connected, no signal")
        XCTAssertNil(ConnectionAdvisor.device(slot(.streaming), now: now))
    }

    func testMissingDeviceAndLowBattery() {
        XCTAssertEqual(ConnectionAdvisor.device(slot(.disconnected, device: nil), now: now)?.fix, .chooseDevice)
        XCTAssertEqual(ConnectionAdvisor.device(slot(.streaming, battery: 8), now: now)?.title, "Battery low (8%)")
        XCTAssertNil(ConnectionAdvisor.device(slot(.streaming, battery: 60), now: now))
    }

    func testReadiness() {
        let streaming = slot(.streaming), waiting = slot(.connecting, waited: 1)
        XCTAssertEqual(RecordReadiness.evaluate(slots: [streaming], phone: nil), .ready)
        XCTAssertEqual(RecordReadiness.evaluate(slots: [streaming, waiting], phone: nil), .partial(streaming: 1, total: 2))
        XCTAssertEqual(RecordReadiness.evaluate(slots: [waiting], phone: nil), .connecting)
        XCTAssertEqual(RecordReadiness.evaluate(slots: [], phone: nil), .blocked("Choose a device"))
        XCTAssertEqual(RecordReadiness.evaluate(slots: [streaming], phone: ConnectionAdvisor.phone(.poweredOff)), .blocked("Bluetooth is off"))
        XCTAssertTrue(RecordReadiness.partial(streaming: 1, total: 2).canRecord)
        XCTAssertFalse(RecordReadiness.connecting.canRecord)
    }

    func testDurationAndElapsedFormats() {
        XCTAssertEqual(Format.duration(9), "9 s")
        XCTAssertEqual(Format.duration(420), "7 min")
        XCTAssertEqual(Format.duration(3900), "1 h 05 min")
        XCTAssertEqual(Format.elapsed(75), "1:15")
    }

    @MainActor func testParticipantColoursAreDistinct() throws {
        let roster = Roster(url: nil)
        let a = try roster.addParticipant("A"), b = try roster.addParticipant("B")
        XCTAssertNotEqual(a.colorIndex, b.colorIndex)
    }
}

final class NamingTests: XCTestCase {
    func testDefaultTagCountsPerDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let sunday = Date(timeIntervalSince1970: 1_758_412_800)          // Sunday 21 Sep 2025, 00:00 UTC
        XCTAssertEqual(Format.weekday(sunday, calendar: calendar), "Sun")
        XCTAssertEqual(Format.weekday(sunday.addingTimeInterval(86_400), calendar: calendar), "Mon")

        let noon = sunday.addingTimeInterval(12 * 3600)
        XCTAssertEqual(Format.defaultTag(now: noon, existing: [], calendar: calendar), "MoRe21/09")
        // Yesterday's recordings don't count: still the first of the day.
        let yesterday = [("Sat01", sunday.addingTimeInterval(-3600))]
        XCTAssertEqual(Format.defaultTag(now: noon, existing: yesterday, calendar: calendar), "MoRe21/09")
        XCTAssertEqual(Format.defaultTag(now: noon, existing: [("MoRe21/09", sunday)], calendar: calendar), "Sun01")
        XCTAssertEqual(Format.defaultTag(now: noon, existing: [("custom", sunday)], calendar: calendar), "Sun01")
        XCTAssertEqual(Format.defaultTag(now: noon, existing: [("MoRe21/09", sunday), ("Sun01", sunday), ("Sun02", sunday)],
                                         calendar: calendar), "Sun03")
        // The slash never reaches the file name.
        XCTAssertTrue(Session.fileName(start: noon, tag: "MoRe21/09").hasSuffix("_MoRe21-09.csv"))
    }

    func testSimulatedDeviceNames() {
        XCTAssertEqual(Validation.deviceID("Simulated3"), "simulated3")
        XCTAssertNil(Validation.deviceID("simulated"))
        XCTAssertNil(Validation.deviceID("simulated123"))
        XCTAssertEqual(Format.device("simulated2"), "simulated2")
        XCTAssertEqual(Format.device("A1B2C3D4"), "C3D4")
        XCTAssertEqual(Format.device("A1B2C3D4", short: false), "A1B2C3D4")
        XCTAssertEqual(Format.liveClock(6), ":06")
        XCTAssertEqual(Format.liveClock(66), "1:06")
        XCTAssertEqual(Format.liveClock(3726), "1:02:06")
    }

    func testZoneColours() {
        XCTAssertEqual(HRZone.level(zone: 1), .easy)
        XCTAssertEqual(HRZone.level(zone: 3), .moderate)
        XCTAssertEqual(HRZone.level(zone: 5), .hard)
    }
}

final class RoutingTests: XCTestCase {
    /// A simulated device must never take over a real one: each ID goes to its own provider.
    func testRealAndSimulatedDevicesUseTheirOwnProvider() {
        let router = RoutingProvider(polar: ScriptedProvider(), simulated: SimulatedProvider(), includeSimulatedInScan: true)
        let config = StreamConfig(accRate: 50, accRange: 8)
        XCTAssertTrue(router.makeSensor(deviceID: "A1B2C3D4", config: config) is ScriptedSensor)     // stands in for real
        XCTAssertTrue(router.makeSensor(deviceID: "simulated1", config: config) is SimulatedSensor)
        let noBluetooth = RoutingProvider(polar: nil, simulated: SimulatedProvider(), includeSimulatedInScan: true)
        XCTAssertTrue(noBluetooth.makeSensor(deviceID: "A1B2C3D4", config: config) is SimulatedSensor)
    }
}
