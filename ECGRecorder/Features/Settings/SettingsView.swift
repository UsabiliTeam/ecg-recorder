import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Roster.self) private var roster
    @Environment(DeviceProviders.self) private var providers

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("People and devices") {
                    link("Participants", count: roster.participants.count) { ParticipantsSettings() }
                    link("Devices", count: roster.devices.count) { DevicesSettings() }
                    link("Saved tags", count: roster.tags.count) { TagsSettings() }
                }
                Section {
                    Picker("RMSSD window", selection: $settings.rmssdWindow) {
                        ForEach([30, 60, 120, 300, 600, 900], id: \.self) { Text(Format.elapsed(TimeInterval($0))).tag($0) }
                    }
                } header: { Text("Recording") } footer: {
                    Text("RMSSD is computed over a rolling window. Changes apply to the next recording.")
                }
                Section {
                    NavigationLink { NotificationSettings() } label: {
                        LabeledContent("Notifications", value: EndSound.name(of: settings.endSound))
                    }
                }
                Section("Heart rate zones") {
                    Toggle("Show HR zone", isOn: $settings.zonesEnabled)
                    if settings.zonesEnabled {
                        Picker("Max HR", selection: $settings.maxHRMethod) {
                            ForEach(HRMaxMethod.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                }
                if providers.canUseHardware {
                    Section {
                        Toggle("Show simulated devices", isOn: $settings.useSimulator)
                    } header: { Text("Developer") } footer: {
                        Text("Adds simulated1 to simulated6 to the device scan. They replay synthetic data; real devices always use Bluetooth and can be used at the same time.")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func link<D: View>(_ title: String, count: Int, @ViewBuilder destination: () -> D) -> some View {
        NavigationLink { destination() } label: { LabeledContent(title, value: "\(count)") }
    }
}
