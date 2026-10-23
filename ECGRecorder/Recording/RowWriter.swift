import Foundation

enum StreamKind: String {
    case ecg = "ECG", hr = "HR", rr = "RR", contact = "CONTACT", event = "EVENT", sync = "SYNC", marker = "MARKER"
}

/// Payload of one row. At most one of the value fields is set; it fills the `value` column.
struct RowFields {
    var ecg: Int32?
    /// A whole ECG packet in one row: microvolts joined by spaces, first sample time in `sensor_time_ns`,
    /// last sample time in `note`.
    var ecgPacket: [Int32]?
    var hr: Int?
    var rr: Double?
    var contact: Bool?
    var ntpOffset: Double?
    var event: String?
    var flag: String?
}

/// Formats one CSV row in `CSVFormat.columns` order.
struct RowFormatter {
    /// `prefix` is the precomputed "participant,device_id," part.
    func line(prefix: String, stream: StreamKind, unix: Double, sensorNs: UInt64?, _ f: RowFields) -> String {
        var s = prefix
        s += stream.rawValue; s += ","
        s += String(format: "%.3f", unix); s += ","
        if let v = sensorNs { s += String(v) }; s += ","
        if let p = f.ecgPacket {
            var first = true
            for v in p { if !first { s += " " }; first = false; s += String(v) }
        }
        else if let v = f.ecg { s += String(v) }
        else if let v = f.hr { s += String(v) }
        else if let v = f.rr { s += String(format: "%.1f", v) }
        else if let v = f.contact { s += v ? "1" : "0" }
        else if let v = f.ntpOffset { s += String(format: "%.6f", v) }
        s += ","
        if let v = f.flag { s += v }; s += ","
        if let v = f.event { s += CSVFormat.escape(v) }
        s += "\n"
        return s
    }
}

enum WriteError: Error { case cannotCreate(String) }

/// Append-only session file. Buffered, flushed by the engine about once per second, synced to disk periodically.
/// Never holds the session in memory.
final class CSVSessionWriter {
    let url: URL
    private let handle: FileHandle
    private var buffer = Data()
    private(set) var rowsWritten = 0

    /// Creates the file with data protection "until first user authentication" so writes continue while locked,
    /// or reopens it for appending when resuming.
    init(url: URL, resume: Bool) throws {
        self.url = url
        if !resume || !FileManager.default.fileExists(atPath: url.path) {
            let ok = FileManager.default.createFile(
                atPath: url.path, contents: Data(CSVFormat.header.utf8),
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            guard ok else { throw WriteError.cannotCreate(url.lastPathComponent) }
        }
        handle = try FileHandle(forWritingTo: url)
        let end = try handle.seekToEnd()
        if resume { try Self.dropTornRow(handle, end: end, url: url) }
        buffer.reserveCapacity(1 << 17)
    }

    /// A kill mid-write can leave a partial last row. Appending to it would merge two rows, and a cut ECG row
    /// still parses as a valid, shorter packet with a wrong last sample, so the fragment is cut back to the
    /// last complete line.
    private static func dropTornRow(_ handle: FileHandle, end: UInt64, url: URL) throws {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let tail = min(end, 64 * 1024)                  // a row is well under 1 KB
        try reader.seek(toOffset: end - tail)
        let bytes = try reader.readToEnd() ?? Data()
        guard let last = bytes.last, last != UInt8(ascii: "\n") else { return }
        guard let newline = bytes.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let keep = end - tail + UInt64(newline - bytes.startIndex + 1)
        try handle.truncate(atOffset: keep)
        try handle.seekToEnd()
    }

    func append(_ line: String) throws {
        buffer.append(contentsOf: line.utf8)
        rowsWritten += 1
        if buffer.count >= 1 << 16 { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func sync() throws { try flush(); try handle.synchronize() }

    func close() throws { try sync(); try handle.close() }
}
