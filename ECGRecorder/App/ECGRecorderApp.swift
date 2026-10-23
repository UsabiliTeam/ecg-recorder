import SwiftUI

@main
struct ECGRecorderApp: App {
    @State private var roster: Roster
    @State private var library: SessionLibrary
    @State private var settings: AppSettings
    @State private var recording: RecordingController
    @State private var providers: DeviceProviders
    @State private var bluetooth: BluetoothMonitor

    init() {
        Notifier.prepare()
        Haptics.prepare()
        let roster = Roster()
        let library = SessionLibrary()
        let settings = AppSettings()
        let providers = DeviceProviders()
        _roster = State(initialValue: roster)
        _library = State(initialValue: library)
        _settings = State(initialValue: settings)
        let bluetooth = BluetoothMonitor(watching: providers.canUseHardware)
        _providers = State(initialValue: providers)
        _bluetooth = State(initialValue: bluetooth)
        _recording = State(initialValue: RecordingController(roster: roster, library: library, settings: settings,
                                                             providers: providers, bluetooth: bluetooth))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(roster)
                .environment(library)
                .environment(settings)
                .environment(recording)
                .environment(providers)
                .environment(bluetooth)
                .task {
                    await library.reload()
                    await recording.resumeIfNeeded()
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            RecordTab().tabItem { Label("Record", systemImage: "waveform.path.ecg") }
            RecordingsTab().tabItem { Label("Recordings", systemImage: "chart.xyaxis.line") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
