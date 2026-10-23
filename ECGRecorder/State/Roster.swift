import Observation
import SwiftUI
import Foundation

/// The "phonebook": participants, saved devices and saved tags. Persisted on every change.
@Observable @MainActor
final class Roster {
    private struct Stored: Codable {
        var participants: [Participant]
        var devices: [String]
        var tags: [String]
    }

    private(set) var participants: [Participant] { didSet { save() } }
    private(set) var devices: [String] { didSet { save() } }
    private(set) var tags: [String] { didSet { save() } }

    @ObservationIgnored private let url: URL?

    /// Pass `url: nil` for an in-memory roster (tests, previews).
    init(url: URL? = AppPaths.rosterFile) {
        self.url = url
        let stored = url.flatMap { JSONFile.read(Stored.self, from: $0) }
        participants = stored?.participants ?? []
        devices = stored?.devices ?? []
        tags = stored?.tags ?? []
    }

    private func save() {
        guard let url else { return }
        try? JSONFile.write(Stored(participants: participants, devices: devices, tags: tags), to: url)
    }

    func participant(_ id: UUID?) -> Participant? {
        guard let id else { return nil }
        return participants.first { $0.id == id }
    }

    func participant(named name: String) -> Participant? { participants.first { $0.pseudonym == name } }

    @discardableResult
    func addParticipant(_ raw: String) throws -> Participant {
        guard let name = Validation.clean(raw, max: Limits.maxPseudonymLength) else { throw RosterError.invalidPseudonym }
        guard !participants.contains(where: { $0.pseudonym == name }) else { throw RosterError.duplicatePseudonym }
        let participant = Participant(pseudonym: name, colorIndex: nextColorIndex())
        participants.append(participant)
        return participant
    }

    /// Lowest palette slot no participant uses; wraps around once all are taken.
    private func nextColorIndex() -> Int {
        let used = Set(participants.compactMap(\.colorIndex))
        return (0..<Palette.participantCount).first { !used.contains($0) } ?? participants.count % Palette.participantCount
    }

    /// Past sessions keep the pseudonym; only the phonebook entry goes.
    func removeParticipant(_ id: UUID) { participants.removeAll { $0.id == id } }

    func addDevice(_ raw: String) throws {
        guard let id = Validation.deviceID(raw) else { throw RosterError.invalidDeviceID }
        guard !devices.contains(id) else { throw RosterError.duplicateDevice }
        devices.append(id)
    }

    func removeDevices(at offsets: IndexSet) { devices.remove(atOffsets: offsets) }

    func addTag(_ raw: String) {
        guard let tag = Validation.clean(raw, max: Limits.maxTagLength), !tags.contains(tag) else { return }
        tags.append(tag)
    }

    func removeTags(at offsets: IndexSet) { tags.remove(atOffsets: offsets) }
}
