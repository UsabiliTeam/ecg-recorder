import SwiftUI

/// What the app alerts about, how, and which sound ends a timed recording.
struct NotificationSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                NavigationLink { EndSoundPicker() } label: {
                    LabeledContent("Timer end sound", value: EndSound.name(of: settings.endSound))
                }
            } footer: {
                Text("Plays when “Stop after” ends a recording.")
            }
            Section {
                ForEach(AlertEvent.allCases) { Toggle($0.title, isOn: settings.binding(for: $0)) }
            } header: { Text("Notify me when") } footer: {
                Text("Problems saving a recording are always shown.")
            }
            Section {
                ForEach(AlertChannel.allCases) { Toggle($0.rawValue, isOn: settings.binding(for: $0)) }
                AlertTestRow()
            } header: { Text("How") } footer: {
                Text("Sound and haptic work in the foreground only. In the background, alerts are lock-screen notifications and follow iOS settings.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Tap a sound to choose it and hear it.
private struct EndSoundPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List(EndSound.options) { option in
            Button {
                settings.endSound = option.id
                EndSound.play(option.id)
            } label: {
                HStack {
                    Text(option.name).foregroundStyle(.primary)
                    Spacer()
                    if option.id == settings.endSound { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .accessibilityAddTraits(option.id == settings.endSound ? .isSelected : [])
        }
        .navigationTitle("Timer end sound")
        .navigationBarTitleDisplayMode(.inline)
    }
}
