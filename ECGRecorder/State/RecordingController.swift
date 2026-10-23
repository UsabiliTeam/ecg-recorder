import Foundation
import Observation
import UIKit
import AudioToolbox

enum RecordingPhase { case setup, recording, saving }

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Owns the record flow: setup (devices connect and stream live, nothing recorded) -> recording -> saved.
/// Streaming, metrics and file writing live in `SessionEngine`; this class only orchestrates and mirrors
/// engine snapshots into UI state.
@Observable @MainActor
final class RecordingController {
    private(set) var phase: RecordingPhase = .setup
    private(set) var slots: [Slot] = []
    private(set) var startedAt: Date?
    /// Name of the recording in progress (the typed name, or the default one).
    private(set) var recordingName = ""
    private(set) var banner: String?
    private(set) var buffers: [UUID: LiveBuffer] = [:]
    private(set) var busy = false
    var tag = ""
    /// Auto-stop: when on, recording stops and saves itself after this many seconds.
    var autoStopEnabled = false
    var autoStopSeconds = 300
    /// Skip-first: when on, the first N seconds after Record is tapped are not written to the file.
    var skipFirstEnabled = false
    var skipFirstSeconds = 20
    /// Predicted RMSSD: when on, the user's guess (ms) is saved in the file's session_info row.
    var predictionEnabled = false
    var predictedRMSSD = 40
    /// A guess only means something for one person, so it is offered for a single participant only.
    var canPredict: Bool { slots.count == 1 }
    /// Set while waiting out the skip; nil once actual recording begins.
    private(set) var startingAt: Date?
    /// Set once actual recording begins with auto-stop on; nil otherwise.
    private(set) var autoStopAt: Date?
    /// Name for the next event marker; empty means the default ("event01", "event02", ...).
    var markerName = ""
    /// Markers set in this recording so far.
    private(set) var markerCount = 0
    /// The most recent marker, for a moment of feedback on screen.
    private(set) var lastMarker: EventMarker?
    var nextMarkerName: String { Validation.clean(markerName, max: Limits.maxTagLength) ?? EventMarker.defaultName(markerCount + 1) }
    /// Set when a recording has just been saved; the UI shows a confirmation and clears it.
    var lastSaved: Session?
    var notice: Notice?

    @ObservationIgnored private let roster: Roster
    @ObservationIgnored private let library: SessionLibrary
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let providers: DeviceProviders
    @ObservationIgnored private let bluetooth: BluetoothMonitor
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private var engine: SessionEngine?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var ntpOffset: Double?
    @ObservationIgnored private var reportedWriteError = false
    @ObservationIgnored private var updateCount = 0
    @ObservationIgnored private var engineKey: EngineKey?
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?
    /// Bumped whenever an engine teardown starts, so a rebuild superseded mid-flight never starts stale.
    @ObservationIgnored private var rebuildGeneration = 0
    /// The recording was resumed after a relaunch: the engine only saw the part after it, so the saved
    /// numbers are recomputed from the whole file.
    @ObservationIgnored private var resumedFile: URL?

    /// What an idle engine was built for; any change means the engine is rebuilt.
    private struct EngineKey: Equatable {
        var devices: [String]
        var rmssdWindow: Int
        var zones: Bool
    }

    /// A recording whose file was touched this recently is resumed after a relaunch.
    private static let resumeWindow: TimeInterval = 600

    init(roster: Roster, library: SessionLibrary, settings: AppSettings, providers: DeviceProviders, bluetooth: BluetoothMonitor) {
        self.bluetooth = bluetooth
        self.roster = roster
        self.library = library
        self.settings = settings
        self.providers = providers
    }

    // MARK: Derived state

    var canAddSlot: Bool { phase == .setup && slots.count < Limits.maxDevices }
    /// Pairs that will be recorded; rows still missing a participant or device are left out.
    var recordable: [Slot] { slots.filter(isComplete) }
    /// Phone-level problem (Bluetooth), nil with simulated devices.
    var phoneProblem: Problem? { needsBluetooth ? ConnectionAdvisor.phone(bluetooth.status) : nil }
    var readiness: RecordReadiness { RecordReadiness.evaluate(slots: recordable, phone: phoneProblem) }
    var canStart: Bool { phase == .setup && !busy && readiness.canRecord }
    /// Name used when the tag is left empty: Sun01, Sun02, ...
    var defaultTag: String { library.nextDefaultTag() }
    /// Count of streaming devices; with exactly one device also its heart rate and zone.
    private var activityState: LiveActivityController.State {
        let total = slots.count
        var state = LiveActivityController.State(connected: slots.filter(\.isStreaming).count, total: total,
                                                 startsAt: startingAt, startedAt: startedAt, autoStopAt: autoStopAt)
        if total == 1, let slot = slots.first, slot.isStreaming, slot.hr > 0 {
            state.hr = slot.hr
            if settings.zonesEnabled {
                let zone = HRZone.zone(hr: slot.hr)
                state.zone = zone
                state.zoneLevel = switch HRZone.level(zone: zone) {
                case .easy: .easy
                case .moderate: .moderate
                case .hard: .hard
                }
            }
        }
        return state
    }
    func isSimulated(_ slot: Slot) -> Bool { providers.isSimulated(slot.deviceID) }

    /// False only when every chosen device is simulated (or there is no Bluetooth at all).
    private var needsBluetooth: Bool {
        guard providers.canUseHardware else { return false }
        let devices = slots.compactMap(\.deviceID)
        return devices.isEmpty || devices.contains { !DeviceID.isSimulated($0) }
    }

    func name(of slot: Slot) -> String { roster.participant(slot.participantID)?.pseudonym ?? "Participant" }

    func isTaken(participant id: UUID, except slot: UUID) -> Bool {
        slots.contains { $0.participantID == id && $0.id != slot }
    }
    func isTaken(device id: String, except slot: UUID) -> Bool {
        slots.contains { $0.deviceID == id && $0.id != slot }
    }

    private func isComplete(_ slot: Slot) -> Bool {
        roster.participant(slot.participantID) != nil && slot.deviceID != nil
    }

    // MARK: Setup

    /// Setup always shows at least one participant-device pair.
    func ensureFirstSlot() {
        guard phase == .setup else { return }
        if slots.isEmpty { addSlot() } else { syncEngine() }
    }

    /// Pre-fills the next unused participant (creating "P<n>" when none is free) and saved device.
    func addSlot() {
        guard canAddSlot else { return }
        let participant = roster.participants.first { p in !slots.contains { $0.participantID == p.id } }
            ?? makeDefaultParticipant()
        let device = roster.devices.first { d in !slots.contains { $0.deviceID == d } }
        slots.append(Slot(participantID: participant?.id, deviceID: device))
        syncEngine()
    }

    private func makeDefaultParticipant() -> Participant? {
        var n = 1
        while roster.participant(named: "P\(n)") != nil { n += 1 }
        return try? roster.addParticipant("P\(n)")
    }

    /// Saves a device picked from a scan and assigns it, unless another row already uses it.
    func useScanned(device id: String, for slot: UUID) {
        try? roster.addDevice(id)
        guard !isTaken(device: id, except: slot) else { return }
        assign(device: id, to: slot)
    }

    func removeSlot(_ id: UUID) {
        guard phase == .setup else { return }
        slots.removeAll { $0.id == id }
        syncEngine()
    }

    func assign(participant id: UUID, to slot: UUID) { mutate(slot) { $0.participantID = id } }
    func assign(device id: String, to slot: UUID) {
        mutate(slot) { $0.deviceID = id }
        syncEngine()
    }

    // MARK: Flow

    /// Devices connect on their own while idle; this rebuilds the connection only when the setup changed.
    func syncEngine() {
        guard phase == .setup else { return }
        let withDevice = slots.filter { $0.deviceID != nil }
        let key = EngineKey(devices: withDevice.compactMap(\.deviceID), 
                            rmssdWindow: settings.rmssdWindow, zones: settings.zonesEnabled)
        guard key != engineKey || engine == nil else { return }
        let old = engine
        engine = nil
        updatesTask?.cancel()
        updatesTask = nil
        buffers = [:]
        for i in slots.indices { slots[i].state = .disconnected }
        engineKey = key
        rebuildGeneration += 1
        let generation = rebuildGeneration
        guard !withDevice.isEmpty else {
            Task { await old?.shutdown() }
            return
        }
        let members = withDevice.map { EngineMember(slotID: $0.id, participant: "", deviceID: $0.deviceID ?? "") }
        for i in slots.indices where slots[i].deviceID != nil {
            slots[i].state = .connecting
            slots[i].waitingSince = .now
        }
        // Wait for the old engine's sensors to fully disconnect (and unregister from the shared
        // PolarHub) before the new engine's sensors register for the same device IDs — otherwise
        // the old sensor's delayed unregister can race the new sensor's register and drop it silently.
        Task {
            await old?.shutdown()
            guard self.rebuildGeneration == generation, self.phase == .setup else { return }
            self.startEngine(members: members)
        }
        if ntpOffset == nil { Task { ntpOffset = await NTPClient.offset() } }
    }

    func start() {
        guard canStart, let engine else { return }
        busy = true
        library.refreshStorage()
        slots = recordable
        let id = UUID()
        let cleanTag = Validation.clean(tag, max: Limits.maxTagLength) ?? defaultTag
        let url = uniqueURL(Session.fileName(start: .now, tag: cleanTag))
        let offset = ntpOffset
        let names = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, name(of: $0)) })
        let skipSeconds = skipFirstEnabled ? skipFirstSeconds : 0
        let prediction = predictionEnabled && canPredict ? predictedRMSSD : nil
        if skipSeconds > 0 {
            startingAt = Date.now.addingTimeInterval(TimeInterval(skipSeconds))
            // Shown now, while the app is surely in front: the phone may be locked by the time the skip ends.
            liveActivity.start(name: cleanTag, state: activityState)
        }
        Task {
            if skipSeconds > 0 { try? await Task.sleep(for: .seconds(skipSeconds)) }
            guard phase == .setup else {   // e.g. the app tore this engine down while waiting
                startingAt = nil
                liveActivity.end()
                busy = false
                return
            }
            let begin = Date.now
            let record = ActiveRecording(id: id, start: begin, tag: cleanTag, fileName: url.lastPathComponent,
                                         members: slots.map { .init(participant: name(of: $0), deviceID: $0.deviceID ?? "") },
                                         predictedRMSSD: prediction)
            do {
                try await engine.startRecording(id: id, tag: cleanTag, start: begin, url: url, resume: false, ntpOffset: offset, names: names,
                                                predictedRMSSD: prediction)
                ActiveRecordingStore.save(record)
                startingAt = nil
                startedAt = begin
                recordingName = cleanTag
                phase = .recording
                if autoStopEnabled { scheduleAutoStop(from: begin) }
                if liveActivity.isActive { liveActivity.update(activityState) } else { liveActivity.start(name: cleanTag, state: activityState) }
                if settings.alertChannels.contains(.haptic), settings.alerts(.started) { Haptics.start() }
                let missing = slots.filter { !$0.isStreaming }.map { name(of: $0) }
                if !missing.isEmpty { raiseAlert("Not recording yet: \(missing.joined(separator: ", "))", for: .notReady) }
                Task { if let o = await NTPClient.offset() { await engine.recordNTPOffset(o, label: "ntp_offset") } }
            } catch {
                startingAt = nil
                liveActivity.end()
                notice = Notice(title: "Can't start recording", message: "The file could not be created. Check free storage.")
            }
            busy = false
        }
    }

    /// Marks this moment in the file. The time is taken here, at the tap, before the hop to the engine.
    func mark() {
        guard phase == .recording, let engine else { return }
        let stamp = Stamp.now()
        let marker = EventMarker(t: stamp.unix, name: nextMarkerName)
        markerCount += 1
        markerName = ""
        lastMarker = marker
        Task { await engine.mark(marker.name, at: stamp) }
    }

    /// Stops and saves on its own once `autoStopSeconds` of actual recording has elapsed.
    private func scheduleAutoStop(from begin: Date) {
        autoStopAt = begin.addingTimeInterval(TimeInterval(autoStopSeconds))
        let seconds = autoStopSeconds
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            let channels = self.settings.alertChannels, sound = self.settings.endSound
            // Haptics and in-process audio only fire while the app is active; locked or backgrounded,
            // only a system notification can make the phone ring and buzz (mirrors raiseAlert below).
            if self.settings.alerts(.timerEnds) {
                if UIApplication.shared.applicationState == .active {
                    if channels.contains(.haptic) { Haptics.autoStopped() }
                    if channels.contains(.sound) { EndSound.play(sound) }
                } else if channels.contains(.lockScreen) {
                    Notifier.post("Recording stopped automatically", sound: EndSound.notificationSound(sound))
                }
            }
            self.stop()
        }
    }

    /// Stopping always saves. Streams keep recording until the file is finalized.
    func stop() {
        guard phase == .recording, !busy, let engine else { return }
        autoStopTask?.cancel()
        autoStopTask = nil
        autoStopAt = nil
        busy = true
        phase = .saving
        liveActivity.end()
        // Auto-stop can fire with the phone locked; ask iOS for time to finish the file even if the
        // Bluetooth streams (which keep the app running in the background) end first.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Save recording")
        Task {
            defer { UIApplication.shared.endBackgroundTask(background) }
            let offset = await NTPClient.offset(timeout: 1.5)   // bounded; never blocks longer
            do {
                let finished = try await engine.stopRecording(ntpOffset: offset)
                if let url = resumedFile {
                    lastSaved = await library.rebuild(url) ?? finished.session
                } else {
                    await library.add(finished)
                    lastSaved = finished.session
                }
                if settings.alertChannels.contains(.haptic), settings.alerts(.saved) { Haptics.success() }
            } catch {
                notice = Notice(title: "Saving problem", message: "The file could not be finalized: \(error.localizedDescription)")
            }
            ActiveRecordingStore.clear()
            tag = ""
            await teardown()
        }
    }

    /// Demo hook, only meaningful with simulated devices.
    func simulateFault(_ id: UUID, noData: Bool) {
        guard let slot = slots.first(where: { $0.id == id }), isSimulated(slot), let engine else { return }
        Task { await engine.injectFault(slot: id, noData: noData) }
    }

    // MARK: Relaunch

    /// Resumes a recording that iOS interrupted (for example after being terminated in the background),
    /// or finalizes it when it is stale.
    func resumeIfNeeded() async {
        liveActivity.end()   // anything still on the lock screen is left over from a terminated run
        guard phase == .setup, let record = ActiveRecordingStore.load() else { return }
        let url = AppPaths.documents.appendingPathComponent(record.fileName)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let fresh = modified.map { Date.now.timeIntervalSince($0) < Self.resumeWindow } ?? false
        let participants = record.members.compactMap { m in roster.participant(named: m.participant).map { ($0, m) } }

        guard fresh, participants.count == record.members.count else {
            ActiveRecordingStore.clear()
            if FileManager.default.fileExists(atPath: url.path) {
                await library.rebuild(url)
                notice = Notice(title: "Recording ended unexpectedly",
                                message: "The app was stopped while recording. Everything captured up to then was saved.")
            }
            return
        }
        slots = participants.map { Slot(participantID: $0.0.id, deviceID: $0.1.deviceID) }
        tag = record.tag
        let members = slots.map { EngineMember(slotID: $0.id, participant: name(of: $0), deviceID: $0.deviceID ?? "") }
        startEngine(members: members)
        for i in slots.indices {
            slots[i].state = .connecting
            slots[i].waitingSince = .now
        }
        guard let engine else { return }
        do {
            try await engine.startRecording(id: record.id, tag: record.tag, start: record.start, url: url, resume: true, ntpOffset: nil,
                                            names: Dictionary(uniqueKeysWithValues: slots.map { ($0.id, name(of: $0)) }),
                                            predictedRMSSD: record.predictedRMSSD)
            resumedFile = url
            startedAt = record.start
            recordingName = record.tag
            phase = .recording
            liveActivity.start(name: record.tag, state: activityState)
            raiseAlert("Recording resumed after the app restarted")
        } catch {
            await teardown()
        }
    }

    // MARK: Engine plumbing

    private func startEngine(members: [EngineMember]) {
        let provider = providers.provider(includeSimulated: settings.useSimulator)
        let config = EngineConfig(rmssdWindow: settings.rmssdWindow, accRate: StreamConfig.accelerometerRate,
                                  accRange: StreamConfig.accelerometerRange, zonesEnabled: settings.zonesEnabled)
        let engine = SessionEngine(members: members, provider: provider, config: config)
        self.engine = engine
        buffers = engine.buffers
        reportedWriteError = false
        updatesTask = Task { [weak self] in
            for await update in engine.updates { self?.apply(update) }
        }
        Task { await engine.begin() }
    }

    /// After a recording (or a failed resume): drop the engine, return to setup and reconnect.
    private func teardown() async {
        busy = true
        let old = engine
        updatesTask?.cancel()
        updatesTask = nil
        engine = nil
        engineKey = nil
        buffers = [:]
        rebuildGeneration += 1
        await old?.shutdown()
        for i in slots.indices { slots[i] = Slot(participantID: slots[i].participantID, deviceID: slots[i].deviceID) }
        liveActivity.end()
        autoStopTask?.cancel()
        autoStopTask = nil
        autoStopAt = nil
        startingAt = nil
        startedAt = nil
        resumedFile = nil
        recordingName = ""
        markerName = ""
        markerCount = 0
        lastMarker = nil
        banner = nil
        phase = .setup
        busy = false
        library.refreshStorage()
        syncEngine()
    }

    private func apply(_ update: EngineUpdate) {
        for i in slots.indices {
            guard let s = update.members[slots[i].id] else { continue }
            let previous = slots[i].state
            if previous != s.link {
                slots[i].state = s.link
                if s.link == .streaming { slots[i].waitingSince = nil; slots[i].hasStreamed = true } else if slots[i].waitingSince == nil { slots[i].waitingSince = .now }
                if phase != .setup, s.link == .disconnected || s.link == .noData {
                    raiseAlert("\(name(of: slots[i])): \(s.link == .noData ? "no data" : "disconnected")", for: .deviceLost)
                }
            }
            if slots[i].hr != s.hr { slots[i].hr = s.hr }
            if slots[i].rmssd != s.rmssd { slots[i].rmssd = s.rmssd }
            if slots[i].battery != s.battery { slots[i].battery = s.battery }
            if s.noisy != (slots[i].noisySince != nil) { slots[i].noisySince = s.noisy ? .now : nil }
        }
        if phase != .setup, let error = update.writeError, !reportedWriteError {
            reportedWriteError = true
            raiseAlert("Writing to disk failed: \(error)")
        }
        if phase == .recording || startingAt != nil { liveActivity.update(activityState) }
        updateCount += 1
        if phase == .recording, updateCount % 30 == 0 {
            library.refreshStorage()
            if let free = StorageMonitor.availableBytes(), free < 300_000_000 { raiseAlert("Storage almost full", for: .storage) }
        }
    }

    /// Called by the screen when the phone's Bluetooth changes; only interrupts while recording.
    func phoneProblemChanged(_ problem: Problem?) {
        guard phase != .setup, let problem else { return }
        raiseAlert(problem.title, for: .bluetooth)
    }

    private func mutate(_ id: UUID, _ change: (inout Slot) -> Void) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        change(&slots[i])
    }

    private func uniqueURL(_ name: String) -> URL {
        var url = AppPaths.documents.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = AppPaths.documents.appendingPathComponent(name.replacingOccurrences(of: ".csv", with: "_\(n).csv"))
            n += 1
        }
        return url
    }

    // MARK: Alerts

    /// `event` nil: always announced (saving problems, a resumed recording).
    private func raiseAlert(_ message: String, for event: AlertEvent? = nil) {
        if let event, !settings.alerts(event) { return }
        let channels = settings.alertChannels
        if channels.contains(.onScreen) {
            banner = message
            bannerTask?.cancel()
            bannerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { self?.banner = nil }
            }
        }
        if UIApplication.shared.applicationState == .active {
            if channels.contains(.haptic) { Haptics.warning() }
            if channels.contains(.sound) { AudioServicesPlaySystemSound(1005) }
        } else if channels.contains(.lockScreen) {
            Notifier.post(message)
        }
    }
}
