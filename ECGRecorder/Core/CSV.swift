import Foundation

enum CSVFormat {
    /// Schema 2. `value` holds the payload of the row's stream: ECG microvolts, HR bpm, RR ms, CONTACT 0/1,
    /// SYNC NTP offset in seconds. Session constants live in the `session_info` SYNC row, not on every row.
    static let schema = 2
    static let columns = ["participant", "device_id", "stream", "unix_time_s", "sensor_time_ns", "value", "flag", "note"]
    static var header: String { columns.joined(separator: ",") + "\n" }

    static func column(_ name: String) -> Int { columns.firstIndex(of: name)! }

    /// Quotes a field when it contains a delimiter, quote or line break.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// One raw field of a line, found without splitting the (possibly very long) rest of it.
    static func field(_ index: Int, of line: String) -> Substring? {
        let bytes = line.utf8
        var commas = 0
        var quoted = false
        var start = bytes.startIndex
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { quoted.toggle() }
            else if c == UInt8(ascii: ","), !quoted {
                if commas == index { return line[start..<i] }
                commas += 1
                start = bytes.index(after: i)
            }
            i = bytes.index(after: i)
        }
        return commas == index ? line[start...] : nil
    }

    static func split(_ line: Substring) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var iterator = line.makeIterator()
        var pending: Character? = iterator.next()
        while let c = pending {
            pending = iterator.next()
            if quoted {
                if c == "\"" {
                    if pending == "\"" { current.append("\""); pending = iterator.next() } else { quoted = false }
                } else { current.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { fields.append(current); current = "" }
            else { current.append(c) }
        }
        fields.append(current)
        return fields
    }
}

/// Clocks stamped on every arriving packet.
struct Stamp: Sendable {
    /// Phone monotonic clock in seconds; immune to wall-clock adjustments.
    let mono: Double
    /// UTC Unix time in seconds from the iOS clock.
    let unix: Double

    static func now() -> Stamp {
        Stamp(mono: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9, unix: Date().timeIntervalSince1970)
    }
}
