import Foundation

/// Phone Bluetooth state, reduced to what the user can act on.
enum BluetoothStatus: Sendable, Equatable {
    /// `unknown` (before the first callback) counts as usable so the UI doesn't flash a warning at launch.
    case unknown, ready, poweredOff, unauthorized, unsupported, resetting

    var isUsable: Bool { self == .unknown || self == .ready }
}

/// What the user can do about a problem.
enum Fix: Sendable, Equatable {
    case openSettings
    case chooseDevice
}

struct Problem: Sendable, Equatable {
    enum Severity: Sendable { case blocking, warning }
    let severity: Severity
    /// Short, fits one line under a participant name.
    let title: String
    /// One sentence saying what to try.
    let hint: String
    var fix: Fix?
}

/// Turns raw link state and timing into a plain-language diagnosis. Pure: no I/O, no clock of its own.
enum ConnectionAdvisor {
    /// Time a device may take to connect or deliver data before we say something.
    static let connectGrace: TimeInterval = 12
    static let noSignalGrace: TimeInterval = 8
    static let lowBattery = 10
    /// Noise must last this long before we mention it, so a single movement doesn't raise a warning.
    static let noiseGrace: TimeInterval = 5

    static func phone(_ status: BluetoothStatus) -> Problem? {
        switch status {
        case .unknown, .ready:
            nil
        case .poweredOff:
            Problem(severity: .blocking, title: "Bluetooth is off",
                    hint: "Turn on Bluetooth in Control Center to connect the devices.", fix: .openSettings)
        case .unauthorized:
            Problem(severity: .blocking, title: "Bluetooth access is off",
                    hint: "Allow Bluetooth for this app in Settings to connect the devices.", fix: .openSettings)
        case .unsupported:
            Problem(severity: .blocking, title: "Bluetooth isn't available",
                    hint: "This device can't connect to devices. Use an iPhone.", fix: nil)
        case .resetting:
            Problem(severity: .warning, title: "Bluetooth is restarting", hint: "Devices reconnect on their own in a moment.", fix: nil)
        }
    }

    /// The most useful thing to tell about one device, or nil when all is well (or still within the grace period).
    static func device(_ slot: Slot, now: Date) -> Problem? {
        guard let device = slot.deviceID else {
            return Problem(severity: .blocking, title: "No device chosen", hint: "Pick a device for this participant.", fix: .chooseDevice)
        }
        if slot.isStreaming {
            if let since = slot.noisySince, now.timeIntervalSince(since) >= noiseGrace {
                return Problem(severity: .warning, title: "Noisy signal",
                               hint: "Moisten the electrodes and tighten the strap.", fix: nil)
            }
            guard let level = slot.battery, level <= lowBattery else { return nil }
            return Problem(severity: .warning, title: "Battery low (\(level)%)",
                           hint: "Replace the device's battery before a long recording.", fix: nil)
        }
        let waited = slot.waitingSince.map { now.timeIntervalSince($0) } ?? 0
        switch slot.state {
        case .connected, .noData:
            guard waited > noSignalGrace else { return nil }
            return Problem(severity: .warning, title: "Connected, no signal",
                           hint: "Moisten both electrodes and fasten the device snugly against the skin.", fix: nil)
        case .connecting, .disconnected:
            guard waited > connectGrace else { return nil }
            return Problem(severity: .warning, title: "Can't reach device \(Format.device(device))",
                           hint: "Wet the electrodes to wake it, stay within 1 m, and close other apps using the device.", fix: nil)
        case .streaming:
            return nil
        }
    }
}

/// What the main button does and why, in one place.
enum RecordReadiness: Equatable {
    case blocked(String)
    case connecting
    case ready
    case partial(streaming: Int, total: Int)

    var canRecord: Bool {
        switch self {
        case .ready, .partial: true
        case .blocked, .connecting: false
        }
    }

    var title: String {
        switch self {
        case .blocked(let reason): reason
        case .connecting: "Connecting…"
        case .ready: "Record"
        case .partial(let n, let total): "Record with \(n) of \(total)"
        }
    }

    /// `slots` are the participant-device pairs that would be recorded.
    static func evaluate(slots: [Slot], phone: Problem?) -> RecordReadiness {
        if let phone, phone.severity == .blocking { return .blocked(phone.title) }
        guard !slots.isEmpty else { return .blocked("Choose a device") }
        let streaming = slots.filter(\.isStreaming).count
        if streaming == slots.count { return .ready }
        return streaming > 0 ? .partial(streaming: streaming, total: slots.count) : .connecting
    }
}
