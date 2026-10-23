import Foundation

enum AppPaths {
    /// CSVs live here; the folder is exposed to the Files app.
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// Derived and app-private data: index, phonebook, active-recording marker.
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ECGRecorder", isDirectory: true)
        // The app was renamed from ECGCollector; move an existing install's data across once rather than
        // starting the phonebook and index over.
        let legacy = base.appendingPathComponent("ECGCollector", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let indexDirectory: URL = {
        let dir = support.appendingPathComponent("Index", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let rosterFile = support.appendingPathComponent("roster.json")
    static let activeRecordingFile = support.appendingPathComponent("active-recording.json")
}

/// Small JSON files written atomically with data protection that allows access after first unlock.
enum JSONFile {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum StorageMonitor {
    /// Below this, warn: a long 6-device session can need several GB.
    static let lowThreshold: Int64 = 2_000_000_000

    static func availableBytes() -> Int64? {
        let values = try? AppPaths.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static var isLow: Bool { (availableBytes() ?? .max) < lowThreshold }
}
