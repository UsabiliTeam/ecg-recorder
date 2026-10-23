import Foundation
import CoreBluetooth
import PolarBleSdk
import os

private let log = Logger(subsystem: "com.example.ecgrecorder", category: "polar")

/// Polar BLE SDK behind the `SensorProvider` protocol. One SDK instance serves all devices.
final class PolarProvider: SensorProvider, @unchecked Sendable {
    private let hub = PolarHub()

    /// Created at app launch so Core Bluetooth state restoration can hand connections back.
    init() {}

    func makeSensor(deviceID: String, config: StreamConfig) -> Sensor {
        PolarSensor(deviceID: deviceID, config: config, hub: hub)
    }

    func scan() -> AsyncStream<String> {
        let api = hub.api
        return AsyncStream { c in
            let task = Task {
                do {
                    for try await info in api.searchForDevice(withNameContaining: "H10") { c.yield(info.deviceId) }
                } catch {}
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

/// Shared SDK instance; forwards callbacks to the sensor registered for that device.
final class PolarHub: NSObject, @unchecked Sendable {
    var api: PolarBleApi
    private let lock = NSLock()
    private var sensors: [String: PolarSensor] = [:]

    override init() {
        api = PolarBleApiDefaultImpl.polarImplementation(
            DispatchQueue(label: "ecgrecorder.ble"),
            features: [.feature_hr, .feature_battery_info, .feature_device_info, .feature_polar_online_streaming],
            restoreIdentifier: "com.example.ecgrecorder.central")
        super.init()
        api.observer = self
        api.deviceHrObserver = self
        api.deviceInfoObserver = self
        api.deviceFeaturesObserver = self
    }

    func register(_ sensor: PolarSensor) { lock.lock(); sensors[sensor.deviceID] = sensor; lock.unlock() }
    func unregister(_ sensor: PolarSensor) {
        lock.lock()
        if sensors[sensor.deviceID] === sensor { sensors[sensor.deviceID] = nil }
        lock.unlock()
    }
    fileprivate func sensor(_ id: String) -> PolarSensor? { lock.lock(); defer { lock.unlock() }; return sensors[id] }
}

extension PolarHub: PolarBleApiObserver {
    func deviceConnecting(_ identifier: PolarDeviceInfo) { sensor(identifier.deviceId)?.didChange(.connecting) }
    func deviceConnected(_ identifier: PolarDeviceInfo) { sensor(identifier.deviceId)?.didConnect() }
    func deviceDisconnected(_ identifier: PolarDeviceInfo, info: PolarBleDisconnectInfo) {
        sensor(identifier.deviceId)?.didDisconnect()
    }
    func deviceDisconnected(_ identifier: PolarDeviceInfo, pairingError: Bool) {}
}

extension PolarHub: PolarBleApiDeviceHrObserver {
    func hrValueReceived(_ identifier: String, data: (hr: UInt8, rrs: [Int], rrsMs: [Int], contact: Bool, contactSupported: Bool)) {
        sensor(identifier)?.didReceiveHeart(
            HeartSample(bpm: Int(data.hr), rrMs: Self.fullResolution(data.rrs, ms: data.rrsMs),
                        contact: data.contactSupported ? data.contact : nil))
    }

    /// `rrs` is the device's raw 1/1024 s count; `rrsMs` is the same rounded to whole ms (up to 0.5 ms off,
    /// which matters for small RMSSD values). Uses the raw values when they agree with the rounded ones.
    static func fullResolution(_ raw: [Int], ms: [Int]) -> [Double] {
        let exact = raw.map { Double($0) * 1000 / 1024 }
        let agrees = exact.count == ms.count && zip(exact, ms).allSatisfy { abs($0 - Double($1)) <= 1 }
        return agrees ? exact : ms.map(Double.init)
    }
}

extension PolarHub: PolarBleApiDeviceInfoObserver {
    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) { sensor(identifier)?.didReceiveBattery(Int(batteryLevel)) }
    func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {}
    func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {}
    func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {}
}

extension PolarHub: PolarBleApiDeviceFeaturesObserver {
    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        if feature == .feature_polar_online_streaming { sensor(identifier)?.streamingReady() }
    }

    func bleSdkFeaturesReadiness(_ identifier: String, ready: [PolarBleSdkFeature], unavailable: [PolarBleSdkFeature]) {
        if ready.contains(.feature_polar_online_streaming) { sensor(identifier)?.streamingReady() }
    }
}

final class PolarSensor: Sensor, @unchecked Sendable {
    let deviceID: String
    let events: AsyncStream<SensorEvent>
    private let continuation: AsyncStream<SensorEvent>.Continuation
    private let config: StreamConfig
    private unowned let hub: PolarHub

    private let lock = NSLock()
    private var wanted = false
    private var link: LinkState = .disconnected
    private var lastData = Date.distantPast
    /// ECG can stall while heart rate keeps arriving; the supervisor restarts it on its own clock.
    private var lastEcg = Date.distantPast
    private var streamTasks: [Task<Void, Never>] = []
    private var supervisor: Task<Void, Never>?

    init(deviceID: String, config: StreamConfig, hub: PolarHub) {
        self.deviceID = deviceID
        self.config = config
        self.hub = hub
        var c: AsyncStream<SensorEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    // MARK: Sensor

    func connect() {
        lock.lock()
        wanted = true
        lock.unlock()
        hub.register(self)
        emit(.connecting)
        try? hub.api.connectToDevice(deviceID)
        supervisor?.cancel()
        supervisor = Task { [weak self] in await self?.supervise() }
    }

    func disconnect() {
        lock.lock()
        wanted = false
        streamTasks.forEach { $0.cancel() }; streamTasks = []
        lock.unlock()
        supervisor?.cancel(); supervisor = nil
        try? hub.api.disconnectFromDevice(deviceID)
        hub.unregister(self)
        emit(.disconnected)
    }

    // MARK: Callbacks from the hub

    func didChange(_ state: LinkState) { emit(state) }

    func didConnect() {
        emit(.connected)
        // The SDK reports streaming readiness separately; if it already did, start now.
        if hub.api.isFeatureReady(deviceID, feature: .feature_polar_online_streaming) { streamingReady() }
    }

    func didDisconnect() {
        lock.lock()
        streamTasks.forEach { $0.cancel() }; streamTasks = []
        lock.unlock()
        emit(.disconnected)
    }

    func didReceiveHeart(_ sample: HeartSample) {
        markData()
        continuation.yield(.heart(sample, .now()))
    }

    func didReceiveBattery(_ pct: Int) { continuation.yield(.battery(pct, .now())) }

    /// (Re)starts the ECG and ACC streams; called on every connect and reconnect.
    /// Each stream retries after errors or an unexpected end until the device disconnects.
    func streamingReady() {
        lock.lock()
        guard wanted, streamTasks.isEmpty else { lock.unlock(); return }
        let api = hub.api, id = deviceID, cfg = config
        lastEcg = Date()
        let ecg = retrying("ECG") { [weak self] in
            let available = try await api.requestStreamSettings(id, feature: .ecg)
            for try await packet in api.startEcgStreaming(id, settings: available.maxSettings()) {
                self?.markData(ecg: true)
                let samples = packet.map { EcgSample(sensorNs: $0.timeStamp, microvolts: $0.voltage) }
                self?.continuation.yield(.ecg(samples, .now()))
            }
        }
        guard cfg.accEnabled else { streamTasks = [ecg]; lock.unlock(); return }
        let acc = retrying("ACC") { [weak self] in
            let settings = try PolarSensorSetting([
                .sampleRate: UInt32(cfg.accRate), .resolution: 16, .range: UInt32(cfg.accRange), .channels: 3,
            ])
            for try await packet in api.startAccStreaming(id, settings: settings) {
                self?.markData()
                let samples = packet.map { AccSample(sensorNs: $0.timeStamp, x: $0.x, y: $0.y, z: $0.z) }
                self?.continuation.yield(.acc(samples, .now()))
            }
        }
        streamTasks = [ecg, acc]
        lock.unlock()
    }

    private func retrying(_ name: String, _ body: @escaping () async throws -> Void) -> Task<Void, Never> {
        let id = deviceID
        return Task {
            while !Task.isCancelled {
                do { try await body() } catch { log.error("\(name) stream on \(id) failed: \(error.localizedDescription)") }
                if Task.isCancelled { return }
                log.info("\(name) stream on \(id) ended; retrying")
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func restartStreams() {
        lock.lock()
        streamTasks.forEach { $0.cancel() }; streamTasks = []
        lock.unlock()
        streamingReady()
    }

    // MARK: State

    private func markData(ecg: Bool = false) {
        lock.lock()
        lastData = Date()
        if ecg { lastEcg = lastData }
        let recovered = link == .connected || link == .noData
        lock.unlock()
        if recovered { emit(.streaming) }
    }

    private func emit(_ state: LinkState) {
        lock.lock()
        guard link != state else { lock.unlock(); return }
        link = state
        lock.unlock()
        continuation.yield(.link(state))
    }

    /// Retries dropped connections and flags silence as "no data".
    private func supervise() async {
        var lastAttempt = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let (state, silent, ecgSilent, streams, isWanted) = lock.withLock {
                (link, Date().timeIntervalSince(lastData), Date().timeIntervalSince(lastEcg), !streamTasks.isEmpty, wanted)
            }
            guard isWanted else { return }
            switch state {
            case .disconnected where Date().timeIntervalSince(lastAttempt) > 3:
                lastAttempt = Date()
                emit(.connecting)
                try? hub.api.connectToDevice(deviceID)
            case .streaming where silent > 5:
                emit(.noData)
                restartStreams()
            case .streaming where streams && ecgSilent > 8:
                log.error("ECG on \(self.deviceID) silent for \(Int(ecgSilent)) s while HR flows; restarting")
                restartStreams()
            default: break
            }
        }
    }
}
