import Foundation

struct EngineConfig: Sendable {
    var rmssdWindow: Int
    var accRate: Int
    var accRange: Int
    var zonesEnabled: Bool
}

struct EngineMember: Sendable {
    let slotID: UUID
    let participant: String
    let deviceID: String
}

struct LiveSnapshot: Sendable {
    var link: LinkState = .disconnected
    var hr = 0
    var rmssd: Double?
    var battery: Int?
    /// The ECG or the beats look noisy right now (`SignalQuality`); the UI decides when to say so.
    var noisy = false
}

struct EngineUpdate: Sendable {
    var members: [UUID: LiveSnapshot]
    var writeError: String?
}

struct IndexPoint: Codable, Sendable {
    var t: Double
    var hr: Double?
    var rmssd: Double?
    var sdnn: Double?
    var pnn50: Double?
}

struct FinishedRecording: Sendable {
    let session: Session
    let traces: [String: [IndexPoint]]
}

/// Streams in, CSV rows and live metrics out. Data reaches the file first; the UI only receives snapshots
/// and reads the live buffers. All state is isolated to this actor.
actor SessionEngine {
    private final class Runtime {
        var member: EngineMember
        let sensor: Sensor
        let buffer = LiveBuffer()
        /// Runs from connection on and drives the live numbers.
        var live: LiveAnalyzer
        /// Starts with the file and sees exactly what the file holds, so traces and totals can be rebuilt from it.
        var recorded: RecordingAnalysis
        var snapshot = LiveSnapshot()
        var lost = false
        var linePrefix = ","
        var contact: Bool?
        var task: Task<Void, Never>?

        init(member: EngineMember, sensor: Sensor, window: Int) {
            self.member = member
            self.sensor = sensor
            live = LiveAnalyzer(windowSeconds: window)
            recorded = RecordingAnalysis(windowSeconds: window)
        }
    }

    nonisolated let buffers: [UUID: LiveBuffer]
    nonisolated let updates: AsyncStream<EngineUpdate>
    private let updateSink: AsyncStream<EngineUpdate>.Continuation

    private let config: EngineConfig
    private var runtimes: [UUID: Runtime] = [:]
    private var order: [UUID] = []
    private var ticker: Task<Void, Never>?

    private var file: CSVSessionWriter?
    private var fileName = ""
    private let formatter = RowFormatter()
    private let sessionPrefix = ",,"
    private var sessionID = UUID()
    private var sessionTag = ""
    private var sessionStart = Date()
    private var predictedRMSSD: Int?
    private var markers: [EventMarker] = []
    private var writeError: String?
    private var tickCount = 0

    init(members: [EngineMember], provider: SensorProvider, config: EngineConfig) {
        var sink: AsyncStream<EngineUpdate>.Continuation!
        let stream = AsyncStream<EngineUpdate>(bufferingPolicy: .bufferingNewest(1)) { sink = $0 }
        let streamConfig = StreamConfig(accRate: config.accRate, accRange: config.accRange)
        var built: [UUID: Runtime] = [:]
        var buffers: [UUID: LiveBuffer] = [:]
        for m in members {
            let rt = Runtime(member: m, sensor: provider.makeSensor(deviceID: m.deviceID, config: streamConfig),
                             window: config.rmssdWindow)
            built[m.slotID] = rt
            buffers[m.slotID] = rt.buffer
        }
        self.config = config
        self.updates = stream
        self.updateSink = sink
        self.runtimes = built
        self.order = members.map(\.slotID)
        self.buffers = buffers
    }

    // MARK: Lifecycle

    /// Connects every device and keeps the live view updated. Nothing is written until `startRecording`.
    func begin() {
        for rt in runtimes.values {
            rt.task = Task { [weak self] in
                for await event in rt.sensor.events {
                    await self?.handle(event, rt)
                }
            }
            rt.sensor.connect()
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
    }

    func shutdown() {
        ticker?.cancel()
        for rt in runtimes.values { rt.task?.cancel(); rt.sensor.disconnect() }
        try? file?.close()
        file = nil
        updateSink.finish()
    }

    /// Current live state of one device; lets callers (tests) wait for events to be processed.
    func snapshot(of slot: UUID) -> LiveSnapshot? { runtimes[slot]?.snapshot }

    func injectFault(slot: UUID, noData: Bool) { runtimes[slot]?.sensor.injectFault(noData: noData) }

    // MARK: Recording

    func startRecording(id: UUID, tag: String, start: Date, url: URL, resume: Bool, ntpOffset: Double?,
                        names: [UUID: String], predictedRMSSD: Int? = nil) throws {
        let f = try CSVSessionWriter(url: url, resume: resume)
        fileName = url.lastPathComponent
        sessionID = id; sessionTag = tag; sessionStart = start
        self.predictedRMSSD = predictedRMSSD
        markers = []
        let prediction = predictedRMSSD.map { "predicted_rmssd_ms=\($0);" } ?? ""
        for rt in runtimes.values {
            if let name = names[rt.member.slotID] {
                rt.member = EngineMember(slotID: rt.member.slotID, participant: name, deviceID: rt.member.deviceID)
            }
            rt.linePrefix = "\(CSVFormat.escape(rt.member.participant)),\(rt.member.deviceID),"
            rt.contact = nil
            rt.recorded = RecordingAnalysis(windowSeconds: config.rmssdWindow)
        }
        file = f
        // Anchors: wall clock plus monotonic, per device, so the file is self-contained.
        let stamp = Stamp.now()
        // The tag is last so its own separators cannot confuse the key=value parsing.
        writeSession(.sync, stamp, RowFields(event: "session_info;schema=\(CSVFormat.schema);id=\(id.uuidString);"
            + "rmssd_window_s=\(config.rmssdWindow);unix_s=\(String(format: "%.6f", stamp.unix));"
            + "mono_s=\(String(format: "%.6f", stamp.mono));\(prediction)tag=\(tag)"))
        for id in order {
            guard let rt = runtimes[id] else { continue }
            write(rt, .sync, stamp, nil, RowFields(ntpOffset: ntpOffset, event: resume ? "session_resume" : "session_start"))
        }
        try? f.sync()
    }

    /// Late NTP result, recorded when it arrives.
    func recordNTPOffset(_ offset: Double, label: String) {
        guard file != nil else { return }
        let stamp = Stamp.now()
        writeSession(.sync, stamp, RowFields(ntpOffset: offset, event: label))
    }

    /// A user-marked event; `stamp` is taken at the tap, not when this actor gets to it. `name` is already cleaned.
    func mark(_ name: String, at stamp: Stamp) {
        guard file != nil else { return }
        writeSession(.marker, stamp, RowFields(event: name))
        markers.append(EventMarker(t: (stamp.unix * 1000).rounded() / 1000, name: name))
    }

    func stopRecording(ntpOffset: Double?) throws -> FinishedRecording {
        let stamp = Stamp.now()
        // Artifacts need the beats after each interval, so the saved numbers are computed here, over everything.
        var results: [UUID: RecordingAnalysis.Result] = [:]
        for id in order {
            guard let rt = runtimes[id] else { continue }
            let result = rt.recorded.finish()
            results[id] = result
            write(rt, .sync, stamp, nil, RowFields(ntpOffset: ntpOffset, event: "session_stop" + result.summary.note))
        }
        try file?.close()
        file = nil
        let traces = Dictionary(uniqueKeysWithValues: order.compactMap { id in
            runtimes[id].map { ($0.member.participant, results[id]?.trace ?? []) }
        })
        let duration = Date.now.timeIntervalSince(sessionStart)
        // Only meaningful for a single participant; a multi-participant session has no one "session average".
        let solo = order.count == 1 ? order.first.flatMap { results[$0]?.summary } : nil
        let session = Session(id: sessionID, start: sessionStart, duration: duration, tag: sessionTag,
                              participants: order.compactMap { runtimes[$0]?.member.participant },
                              fileName: fileName, avgHR: solo?.meanHR,
                              avgRMSSD: solo?.rmssd,
                              predictedRMSSD: predictedRMSSD, markers: markers.isEmpty ? nil : markers)
        return FinishedRecording(session: session, traces: traces)
    }

    // MARK: Routing

    private func handle(_ event: SensorEvent, _ rt: Runtime) {
        switch event {
        case .link(let state):
            rt.snapshot.link = state
            recordLinkChange(rt, state)
        case .ecg(let samples, let stamp):
            rt.buffer.append(samples.map(\.microvolts))
            guard file != nil, let first = samples.first, let last = samples.last else { return }
            // One row per packet. `stamp` is when the packet arrived, i.e. when the last sample was taken.
            let back = Double(last.sensorNs &- first.sensorNs) / 1e9
            write(rt, .ecg, stamp, first.sensorNs,
                  RowFields(ecgPacket: samples.map(\.microvolts), event: String(last.sensorNs)), back: back)
        case .acc:
            break                       // accelerometer is not collected
        case .heart(let sample, let stamp):
            handleHeart(sample, stamp, rt)
        case .battery(let pct, _):
            rt.snapshot.battery = pct       // shown in the UI only; not recorded
        }
    }

    private func handleHeart(_ h: HeartSample, _ stamp: Stamp, _ rt: Runtime) {
        rt.snapshot.hr = h.bpm
        write(rt, .hr, stamp, nil, RowFields(hr: h.bpm))
        if h.contact != rt.contact {
            rt.contact = h.contact
            if let c = h.contact { write(rt, .contact, stamp, nil, RowFields(contact: c)) }
        }
        let t = (stamp.unix * 1000).rounded() / 1000     // as the row's unix_time_s reads back
        for raw in h.rrMs {
            let rr = RRQuality.rounded(raw)
            let flag = RRQuality.flag(rr: rr, contact: h.contact)
            // Flagged intervals are kept in the file but never enter the metrics.
            write(rt, .rr, stamp, nil, RowFields(rr: rr, flag: flag))
            rt.live.add(rr: rr, deviceFlag: flag, at: t)
            rt.snapshot.rmssd = rt.live.latest["rmssd"]
            guard file != nil else { continue }
            rt.recorded.add(rr: rr, deviceFlag: flag, at: t, hr: h.bpm)
        }
    }

    /// A lost link breaks the beat sequence. While recording it is also logged, and the rebuilder applies the
    /// same break when it reads the EVENT row back.
    private func recordLinkChange(_ rt: Runtime, _ state: LinkState) {
        if state == .disconnected || state == .noData { rt.live.gap(); rt.snapshot.rmssd = nil }
        guard file != nil else { return }
        let stamp = Stamp.now()
        switch state {
        case .disconnected:
            rt.lost = true
            rt.recorded.gap()
            write(rt, .event, stamp, nil, RowFields(event: "disconnect"))
        case .noData:
            rt.lost = true
            rt.recorded.gap()
            write(rt, .event, stamp, nil, RowFields(event: "no_data"))
        case .streaming where rt.lost:
            rt.lost = false
            write(rt, .event, stamp, nil, RowFields(event: "reconnect"))
        default: break
        }
    }

    // MARK: Output

    private func write(_ rt: Runtime, _ stream: StreamKind, _ stamp: Stamp, _ sensorNs: UInt64?,
                       _ fields: RowFields, back: Double = 0) {
        guard let file else { return }
        let line = formatter.line(prefix: rt.linePrefix, stream: stream, unix: stamp.unix - back,
                                  sensorNs: sensorNs, fields)
        do { try file.append(line) } catch { writeError = error.localizedDescription }
    }

    private func writeSession(_ stream: StreamKind, _ stamp: Stamp, _ fields: RowFields) {
        guard let file else { return }
        let line = formatter.line(prefix: sessionPrefix, stream: stream, unix: stamp.unix,
                                  sensorNs: nil, fields)
        do { try file.append(line) } catch { writeError = error.localizedDescription }
    }

    private func tick() {
        tickCount += 1
        do {
            try file?.flush()
            if tickCount % 10 == 0 { try file?.sync() }
        } catch { writeError = error.localizedDescription }
        for rt in runtimes.values {
            let streaming = rt.snapshot.link == .streaming
            let kurtosis = streaming ? SignalQuality.kurtosis(rt.buffer.latest(SignalQuality.seconds * LiveBuffer.rate)) : nil
            rt.snapshot.noisy = streaming && SignalQuality.isNoisy(kurtosis: kurtosis, artifactShare: rt.live.artifactShare)
        }
        updateSink.yield(EngineUpdate(members: runtimes.mapValues(\.snapshot), writeError: writeError))
    }
}
