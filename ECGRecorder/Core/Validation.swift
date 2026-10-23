import Foundation

/// All user-entered text passes through here before it is stored or used in a file name.
enum Validation {
    /// Trims, drops control characters (a line break would split a CSV row for line-based readers) and leading
    /// `= + - @`, which spreadsheets run as a formula when the CSV is opened (CSV injection).
    static func clean(_ raw: String, max: Int) -> String? {
        let printable = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        let formulaStart: Set<Character> = ["=", "+", "-", "@"]
        let text = String(printable.drop { $0.isWhitespace || formulaStart.contains($0) }
            .trimmingCharacters(in: .whitespaces).prefix(max))
        return text.isEmpty ? nil : text
    }

    /// H10 IDs are 8 hex characters; simulated devices are "simulated1", "simulated2", ...
    static func deviceID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if DeviceID.isSimulated(trimmed.lowercased()) { return trimmed.lowercased() }
        let id = trimmed.uppercased()
        return id.count == Limits.deviceIDLength && id.allSatisfy(\.isHexDigit) ? id : nil
    }

    static func fileSafe(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" ? Character(scalar) : "-"
        })
    }
}

enum DeviceID {
    static let simulatedPrefix = "simulated"

    /// "simulated" followed by a number of one or two digits.
    static func isSimulated(_ id: String) -> Bool {
        guard id.hasPrefix(simulatedPrefix) else { return false }
        let number = id.dropFirst(simulatedPrefix.count)
        return (1...2).contains(number.count) && number.allSatisfy(\.isNumber)
    }
}

enum RosterError: LocalizedError {
    case invalidPseudonym, duplicatePseudonym, invalidDeviceID, duplicateDevice

    var errorDescription: String? {
        switch self {
        case .invalidPseudonym: "Enter 1 to \(Limits.maxPseudonymLength) characters."
        case .duplicatePseudonym: "That pseudonym already exists."
        case .invalidDeviceID: "Enter the \(Limits.deviceIDLength)-character H10 ID (0-9, A-F)."
        case .duplicateDevice: "That device is already saved."
        }
    }
}
