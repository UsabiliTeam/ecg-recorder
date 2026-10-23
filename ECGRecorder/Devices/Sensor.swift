import Foundation

struct EcgSample: Sendable { let sensorNs: UInt64; let microvolts: Int32 }
struct AccSample: Sendable { let sensorNs: UInt64; let x: Int32; let y: Int32; let z: Int32 }
/// `rrMs` at the device's full resolution (the H10 measures RR in 1/1024 s).
struct HeartSample: Sendable { let bpm: Int; let rrMs: [Double]; let contact: Bool? }

/// Everything a device can tell us. Packets carry the phone clocks at arrival.
enum SensorEvent: Sendable {
    case link(LinkState)
    case ecg([EcgSample], Stamp)
    case acc([AccSample], Stamp)
    case heart(HeartSample, Stamp)
    case battery(Int, Stamp)
}

struct StreamConfig: Sendable {
    /// Fixed accelerometer settings, used if collection is switched on (`accEnabled`). No user option.
    static let accelerometerRate = 200
    static let accelerometerRange = 8

    var accRate: Int
    var accRange: Int
    /// ACC collection is switched off for now (unused, and it dominates file size). Flip to bring it back.
    var accEnabled = false
}

/// One device. Implementations own connection retries and stream restarts; the recorder only reads `events`.
protocol Sensor: AnyObject, Sendable {
    var events: AsyncStream<SensorEvent> { get }
    /// Begin connecting and keep reconnecting until `disconnect()`.
    func connect()
    func disconnect()
    /// Demo hook for simulated sensors.
    func injectFault(noData: Bool)
}

extension Sensor {
    func injectFault(noData: Bool) {}
}

/// Creates sensors and scans for devices. Swapping the provider swaps real hardware for simulation.
protocol SensorProvider: Sendable {
    func makeSensor(deviceID: String, config: StreamConfig) -> Sensor
    /// H10 IDs seen nearby, until cancelled.
    func scan() -> AsyncStream<String>
}
