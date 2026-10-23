import Observation
import SwiftUI
import Foundation

/// The "phonebook": participants, saved devices, saved tags and condition labels. Persisted on every change.
@Observable @MainActor
final class Roster {
    private struct Stored: Codable {
        var participants: [Participant]
        var devices: [String]
        var tags: [String]
        /// Optional so rosters saved before labels existed still decode; nil means "never edited" (presets).
        var labels: [ConditionLabel]?
    }

    private(set) var participants: [Participant] { didSet { save() } }
    private(set) var devices: [String] { didSet { save() } }
    private(set) var tags: [String] { didSet { save() } }
    private(set) var labels: [ConditionLabel] { didSet { save() } }

    @ObservationIgnored private let url: URL?

    /// Pass `url: nil` for an in-memory roster (tests, previews).
    init(url: URL? = AppPaths.rosterFile) {
        self.url = url
        let stored = url.flatMap { JSONFile.read(Stored.self, from: $0) }
        participants = stored?.participants ?? []
        devices = stored?.devices ?? []
        tags = stored?.tags ?? []
        labels = stored?.labels ?? ConditionLabel.presets.enumerated().map { ConditionLabel(name: $1, colorIndex: $0) }
    }

    private func save() {
        guard let url else { return }
        try? JSONFile.write(Stored(participants: participants, devices: devices, tags: tags, labels: labels), to: url)
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

    // MARK: Condition labels

    func label(named name: String) -> ConditionLabel? { labels.first { $0.name == name } }

    /// Lowest palette slot no label uses.
    var nextLabelColor: Int {
        let used = Set(labels.map(\.colorIndex))
        return (0..<Palette.labels.count).first { !used.contains($0) } ?? labels.count % Palette.labels.count
    }

    @discardableResult
    func addLabel(_ raw: String, colorIndex: Int) throws -> ConditionLabel {
        guard labels.count < ConditionLabel.maxCount else { throw LabelError.tooMany }
        let label = ConditionLabel(name: try labelName(raw, except: nil), colorIndex: colorIndex)
        labels.append(label)
        return label
    }

    /// Past recordings keep the name they were recorded with.
    func updateLabel(_ id: UUID, name raw: String, colorIndex: Int) throws {
        guard let i = labels.firstIndex(where: { $0.id == id }) else { return }
        labels[i].name = try labelName(raw, except: id)
        labels[i].colorIndex = colorIndex
    }

    func removeLabels(at offsets: IndexSet) { labels.remove(atOffsets: offsets) }
    func moveLabels(from source: IndexSet, to destination: Int) { labels.move(fromOffsets: source, toOffset: destination) }

    /// "End" is the built-in button that closes a condition, so no label may share its name.
    private func labelName(_ raw: String, except id: UUID?) throws -> String {
        guard let name = Validation.clean(raw, max: ConditionLabel.maxNameLength) else { throw LabelError.invalidName }
        guard name.caseInsensitiveCompare("End") != .orderedSame,
              !labels.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw LabelError.duplicate }
        return name
    }
}

enum LabelError: LocalizedError {
    case invalidName, duplicate, tooMany

    var errorDescription: String? {
        switch self {
        case .invalidName: "Enter 1 to \(ConditionLabel.maxNameLength) characters."
        case .duplicate: "That name is taken."
        case .tooMany: "Up to \(ConditionLabel.maxCount) labels fit on the recording screen."
        }
    }
}
