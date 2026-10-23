import AVFoundation
import UserNotifications

/// The sound played when "Stop after" ends a recording: the app's own bell (`media/bell.wav`, made by
/// `tools/make_bell.py`), one of iOS's alert tones, or none. iOS lets apps read its alert tones
/// (/System/Library/Audio/UISounds) but not its ringtones, so those are the choices. Loudness follows the
/// media volume.
@MainActor
enum EndSound {
    struct Option: Identifiable, Hashable {
        let id: String
        let name: String
    }

    nonisolated static let bell = "bell"
    nonisolated static let silent = "none"

    private static let systemFolder = URL(fileURLWithPath: "/System/Library/Audio/UISounds")
    /// The classic text tones have file names that say nothing; these are their names in iOS Settings.
    private static let classic = [
        "sms-received1.caf": "Tri-tone", "sms-received2.caf": "Chime", "sms-received3.caf": "Glass",
        "sms-received4.caf": "Horn", "sms-received5.caf": "Bell (iOS)", "sms-received6.caf": "Electronic",
        "alarm.caf": "Alarm", "Doorbell.caf": "Doorbell",
    ]

    /// Bell first, then the tones this phone has (alphabetical), None last. Listed from disk, so a tone missing
    /// on some iOS version is simply not offered.
    static let options: [Option] = {
        let fm = FileManager.default
        var tones = classic.filter { fm.fileExists(atPath: systemFolder.appendingPathComponent($0.key).path) }
            .map { Option(id: $0.key, name: $0.value) }
        let modern = (try? fm.contentsOfDirectory(atPath: systemFolder.appendingPathComponent("New").path)) ?? []
        tones += modern.filter { $0.hasSuffix(".caf") }
            .map { Option(id: "New/\($0)", name: $0.dropLast(4).replacingOccurrences(of: "_", with: " ")) }
        return [Option(id: bell, name: "Bell")] + tones.sorted { $0.name < $1.name } + [Option(id: silent, name: "None")]
    }()

    static func name(of id: String) -> String { options.first { $0.id == id }?.name ?? "Bell" }

    /// Only ids from `options` resolve to a system path, so a stored value can never point anywhere else.
    /// A tone that is gone (for example after an iOS update) falls back to the bell.
    private static func url(for id: String) -> URL? {
        if id == silent { return nil }
        if id != bell, options.contains(where: { $0.id == id }) { return systemFolder.appendingPathComponent(id) }
        return Bundle.main.url(forResource: "bell", withExtension: "wav")
    }

    private static var player: AVAudioPlayer?

    static func play(_ id: String) {
        guard let url = url(for: id) else { return }
        if player?.url != url { player = try? AVAudioPlayer(contentsOf: url) }
        guard let player else { return }
        // .playback (not .ambient) so it still rings with the silent switch on, like an alarm;
        // .duckOthers so it cuts through music playing at the same time.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        player.stop()
        player.currentTime = 0
        player.volume = 1
        player.play()
        Task {
            try? await Task.sleep(for: .seconds(player.duration + 0.2))
            try? session.setActive(false, options: .notifyOthersOnDeactivation)   // un-duck other audio
        }
    }

    /// The same sound for a lock-screen notification. Those can only play files from the app bundle or
    /// Library/Sounds, so a system tone is copied there first.
    static func notificationSound(_ id: String) -> UNNotificationSound? {
        guard let source = url(for: id) else { return nil }
        if source.deletingLastPathComponent() == Bundle.main.bundleURL {
            return UNNotificationSound(named: UNNotificationSoundName(source.lastPathComponent))
        }
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return .default }
        let folder = library.appendingPathComponent("Sounds")
        let name = "end-" + id.replacingOccurrences(of: "/", with: "-")
        let copy = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: copy.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? fm.copyItem(at: source, to: copy)) != nil else { return .default }
        }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }
}
