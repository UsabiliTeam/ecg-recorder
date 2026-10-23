import Observation
import Foundation

/// Recorded sessions, backed by the CSVs (source of truth) and the derived index.
@Observable @MainActor
final class SessionLibrary {
    private(set) var sessions: [Session] = []
    private(set) var lowStorage = false
    @ObservationIgnored private let index: SessionIndexStore
    @ObservationIgnored private let documents: URL

    init(index: SessionIndexStore = SessionIndexStore(), documents: URL = AppPaths.documents) {
        self.index = index
        self.documents = documents
    }

    func csvURL(_ session: Session) -> URL { documents.appendingPathComponent(session.fileName) }

    func refreshStorage() { lowStorage = StorageMonitor.isLow }

    /// Loads the index, drops entries whose CSV is gone, and rebuilds the index for CSVs that lack one.
    func reload() async {
        refreshStorage()
        let index = index, documents = documents
        let (known, orphans) = await Task.detached(priority: .utility) { () -> ([Session], [URL]) in
            let fm = FileManager.default
            index.purgeIfOutdated()
            let indexed = index.loadSessions()
            let files = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
            let csvs = files.filter { $0.pathExtension == "csv" &&
                ($0.lastPathComponent.hasPrefix(Session.fileNamePrefix) || $0.lastPathComponent.hasPrefix(Session.legacyFileNamePrefix)) }
            let names = Set(csvs.map(\.lastPathComponent))
            let alive = indexed.filter { names.contains($0.fileName) }
            for stale in indexed where !names.contains(stale.fileName) { index.delete(stale.id) }
            let have = Set(alive.map(\.fileName))
            return (alive, csvs.filter { !have.contains($0.lastPathComponent) })
        }.value
        sessions = known.sorted { $0.start > $1.start }
        for url in orphans { await rebuild(url) }
    }

    /// Rebuilds one session's index from its CSV.
    @discardableResult
    func rebuild(_ csv: URL) async -> Session? {
        let index = index
        let session = await Task.detached(priority: .utility) { () -> Session? in
            guard let (session, traces) = await IndexRebuilder.rebuild(csv: csv) else { return nil }
            try? index.save(session, traces: traces)
            return session
        }.value
        if let session { insert(session) }
        return session
    }

    func add(_ finished: FinishedRecording) async {
        let index = index
        await Task.detached(priority: .utility) { try? index.save(finished.session, traces: finished.traces) }.value
        insert(finished.session)
        refreshStorage()
    }

    func delete(_ session: Session) {
        try? FileManager.default.removeItem(at: csvURL(session))
        index.delete(session.id)
        sessions.removeAll { $0.id == session.id }
        refreshStorage()
    }

    func traces(for session: Session) async -> [String: [IndexPoint]] {
        let index = index
        return await Task.detached(priority: .userInitiated) { index.traces(for: session.id) }.value
    }

    /// One series per session that includes the participant, oldest first.
    func timeline(for pseudonym: String) async -> [String: [IndexPoint]] {
        let relevant = sessions.filter { $0.participants.contains(pseudonym) }.sorted { $0.start < $1.start }
        let index = index
        return await Task.detached(priority: .userInitiated) {
            var out: [String: [IndexPoint]] = [:]
            for s in relevant {
                if let points = index.traces(for: s.id)[pseudonym], !points.isEmpty { out[s.id.uuidString] = points }
            }
            return out
        }.value
    }

    /// See `Format.defaultTag`: "MoRe29/09" first each day, then "Tue01", "Tue02", ...
    func nextDefaultTag(now: Date = .now, calendar: Calendar = .current) -> String {
        Format.defaultTag(now: now, existing: sessions.map { ($0.tag, $0.start) }, calendar: calendar)
    }

    private func insert(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        sessions.sort { $0.start > $1.start }
    }
}
