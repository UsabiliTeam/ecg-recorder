import Observation

/// Holds the real Bluetooth provider (device builds only) and the simulator.
/// Each device is served by the right one: simulated ones by name, everything else over Bluetooth.
@Observable @MainActor
final class DeviceProviders {
    @ObservationIgnored private let polar: SensorProvider?
    @ObservationIgnored private let simulated = SimulatedProvider()

    /// Created at launch so Core Bluetooth state restoration can reconnect devices after a relaunch.
    init() {
        #if targetEnvironment(simulator) || !canImport(PolarBleSdk)   // no Bluetooth: Simulator, or the Mac test package
        polar = nil
        #else
        polar = PolarProvider()
        #endif
    }

    var canUseHardware: Bool { polar != nil }

    /// True for "simulated1"...; also for every device where there is no Bluetooth (the Simulator).
    func isSimulated(_ deviceID: String?) -> Bool {
        guard let deviceID else { return false }
        return polar == nil || DeviceID.isSimulated(deviceID)
    }

    /// `includeSimulated` adds simulated devices to the scan list (always, without Bluetooth).
    func provider(includeSimulated: Bool) -> SensorProvider {
        RoutingProvider(polar: polar, simulated: simulated, includeSimulatedInScan: includeSimulated || polar == nil)
    }
}

/// Sends each device to the provider that owns it, so real and simulated devices can run side by side.
struct RoutingProvider: SensorProvider {
    let polar: SensorProvider?
    let simulated: SensorProvider
    let includeSimulatedInScan: Bool

    func makeSensor(deviceID: String, config: StreamConfig) -> Sensor {
        if let polar, !DeviceID.isSimulated(deviceID) { return polar.makeSensor(deviceID: deviceID, config: config) }
        return simulated.makeSensor(deviceID: deviceID, config: config)
    }

    func scan() -> AsyncStream<String> {
        let sources = [polar, includeSimulatedInScan ? simulated : nil].compactMap { $0 }
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for source in sources {
                        group.addTask { for await id in source.scan() { continuation.yield(id) } }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
