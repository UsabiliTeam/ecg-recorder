import SwiftUI
import Observation

@Observable @MainActor
final class AppSettings {
    private struct Stored: Codable {
        var rmssdWindow = 60
        var alertChannels: Set<AlertChannel> = [.haptic, .onScreen, .lockScreen]
        var zonesEnabled = false
        var maxHRMethod = HRMaxMethod.ageBased
        var useSimulator = false
        /// Events switched off; stored this way round so events added later start switched on.
        var mutedEvents: Set<AlertEvent> = []
        var endSound = EndSound.bell

        init() {}

        /// Every key is optional: settings saved by an older version keep their values instead of failing to
        /// decode and falling back to the defaults.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Stored()
            rmssdWindow = try c.decodeIfPresent(Int.self, forKey: .rmssdWindow) ?? d.rmssdWindow
            alertChannels = try c.decodeIfPresent(Set<AlertChannel>.self, forKey: .alertChannels) ?? d.alertChannels
            zonesEnabled = try c.decodeIfPresent(Bool.self, forKey: .zonesEnabled) ?? d.zonesEnabled
            maxHRMethod = try c.decodeIfPresent(HRMaxMethod.self, forKey: .maxHRMethod) ?? d.maxHRMethod
            useSimulator = try c.decodeIfPresent(Bool.self, forKey: .useSimulator) ?? d.useSimulator
            mutedEvents = try c.decodeIfPresent(Set<AlertEvent>.self, forKey: .mutedEvents) ?? d.mutedEvents
            endSound = try c.decodeIfPresent(String.self, forKey: .endSound) ?? d.endSound
        }
    }

    var rmssdWindow: Int { didSet { save() } }
    var alertChannels: Set<AlertChannel> { didSet { save() } }
    var zonesEnabled: Bool { didSet { save() } }
    var maxHRMethod: HRMaxMethod { didSet { save() } }
    /// Replay synthetic devices instead of Bluetooth. Always on in the Simulator.
    var useSimulator: Bool { didSet { save() } }
    var mutedEvents: Set<AlertEvent> { didSet { save() } }
    /// `EndSound` option id: played when "Stop after" ends a recording.
    var endSound: String { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let s = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        rmssdWindow = s.rmssdWindow
        alertChannels = s.alertChannels
        zonesEnabled = s.zonesEnabled
        maxHRMethod = s.maxHRMethod
        useSimulator = s.useSimulator
        mutedEvents = s.mutedEvents
        endSound = s.endSound
    }

    private func save() {
        var s = Stored()
        s.rmssdWindow = rmssdWindow
        s.alertChannels = alertChannels
        s.zonesEnabled = zonesEnabled
        s.maxHRMethod = maxHRMethod
        s.useSimulator = useSimulator
        s.mutedEvents = mutedEvents
        s.endSound = endSound
        defaults.set(try? JSONEncoder().encode(s), forKey: key)
    }

    func alerts(_ event: AlertEvent) -> Bool { !mutedEvents.contains(event) }

    func binding(for channel: AlertChannel) -> Binding<Bool> {
        Binding(
            get: { self.alertChannels.contains(channel) },
            set: { on in
                if on { self.alertChannels.insert(channel) } else { self.alertChannels.remove(channel) }
            })
    }

    func binding(for event: AlertEvent) -> Binding<Bool> {
        Binding(
            get: { self.alerts(event) },
            set: { on in
                if on { self.mutedEvents.remove(event) } else { self.mutedEvents.insert(event) }
            })
    }
}
