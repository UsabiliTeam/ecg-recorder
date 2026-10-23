import Foundation

struct SimulatedProvider: SensorProvider {

    func makeSensor(deviceID: String, config: StreamConfig) -> Sensor {
        SimulatedSensor(deviceID: deviceID, config: config)
    }

    func scan() -> AsyncStream<String> {
        AsyncStream { c in
            let task = Task {
                for id in (1...Limits.maxDevices).map { "\(DeviceID.simulatedPrefix)\($0)" } {
                    try? await Task.sleep(for: .seconds(0.5))
                    c.yield(id)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

/// Replays a synthetic H10: ECG 130 Hz, ACC at the configured rate, HR/RR per beat.
final class SimulatedSensor: Sensor, @unchecked Sendable {
    let events: AsyncStream<SensorEvent>
    private let continuation: AsyncStream<SensorEvent>.Continuation
    private let config: StreamConfig
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var pendingFault: Bool?   // noData flag of a requested fault
    private let clockOffsetNs = UInt64.random(in: 0...5_000_000_000)

    init(deviceID: String, config: StreamConfig) {
        self.config = config
        var c: AsyncStream<SensorEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    func connect() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel(); task = nil
        continuation.yield(.link(.disconnected))
    }

    func injectFault(noData: Bool) {
        lock.lock(); pendingFault = noData; lock.unlock()
    }

    private func takeFault() -> Bool? {
        lock.lock(); defer { lock.unlock() }
        defer { pendingFault = nil }
        return pendingFault
    }

    private func sensorNs(_ unix: Double) -> UInt64 {
        UInt64(max(0, unix - 946_684_800) * 1e9) &+ clockOffsetNs
    }

    private func run() async {
        var hr = Double.random(in: 62...78)
        var wave = 0.0                  // ECG phase clock, seconds
        var ecgDue = 0.0, accDue = 0.0
        var nextBeat = 0.0
        var lastBatteryReport = -100.0
        let step = 0.1

        continuation.yield(.link(.connecting))
        try? await Task.sleep(for: .seconds(Double.random(in: 0.6...1.6)))
        continuation.yield(.link(.connected))
        try? await Task.sleep(for: .seconds(0.8))
        continuation.yield(.link(.streaming))

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(step))
            if let noData = takeFault() {
                continuation.yield(.link(noData ? .noData : .disconnected))
                try? await Task.sleep(for: .seconds(4))
                if !noData {
                    continuation.yield(.link(.connecting))
                    try? await Task.sleep(for: .seconds(1.5))
                    continuation.yield(.link(.connected))
                }
                continuation.yield(.link(.streaming))
                continue
            }
            let stamp = Stamp.now()
            hr = min(170, max(50, hr + Double.random(in: -0.6...0.6)))

            // ECG: 13 samples per 0.1 s, timestamped backwards from packet arrival
            var volts: [Int32] = []
            ecgDue += 13
            while ecgDue >= 1 {
                ecgDue -= 1
                wave += 1.0 / 130
                volts.append(Int32(ECGSynth.sample(at: wave, hr: Int(hr)) * 1000))
            }
            let ecg = volts.enumerated().map { i, v in
                EcgSample(sensorNs: sensorNs(stamp.unix - Double(volts.count - 1 - i) / 130), microvolts: v)
            }
            continuation.yield(.ecg(ecg, stamp))

            // ACC, timestamped backwards from packet arrival
            if config.accEnabled { accDue += Double(config.accRate) * step }
            var count = 0
            while accDue >= 1 { accDue -= 1; count += 1 }
            let acc = (0..<count).map { i in
                AccSample(sensorNs: sensorNs(stamp.unix - Double(count - 1 - i) / Double(config.accRate)),
                          x: .random(in: -30...30), y: .random(in: -30...30), z: .random(in: 980...1020))
            }
            if !acc.isEmpty { continuation.yield(.acc(acc, stamp)) }

            // HR / RR once per beat
            nextBeat -= step
            if nextBeat <= 0 {
                let rr = 60000 / hr + Double.random(in: -25...25)
                nextBeat += rr / 1000
                continuation.yield(.heart(HeartSample(bpm: Int(hr), rrMs: [(rr * 1024 / 1000).rounded() * 1000 / 1024], contact: true), stamp))
            }
            if stamp.mono - lastBatteryReport > 60 {
                lastBatteryReport = stamp.mono
                continuation.yield(.battery(Int.random(in: 70...95), stamp))
            }
        }
    }
}

/// Synthetic PQRST waveform used by the simulated device.
enum ECGSynth {
    static func sample(at t: Double, hr: Int) -> Double {
        let period = 60.0 / Double(max(hr, 40))
        let phase = t.truncatingRemainder(dividingBy: period) / period
        func bump(_ center: Double, _ width: Double, _ amp: Double) -> Double {
            amp * exp(-pow((phase - center) / width, 2) / 2)
        }
        return bump(0.18, 0.025, 0.12) + bump(0.30, 0.008, -0.12) + bump(0.32, 0.008, 1.0)
            + bump(0.34, 0.008, -0.25) + bump(0.55, 0.05, 0.25)
    }
}
