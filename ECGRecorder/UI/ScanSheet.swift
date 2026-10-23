import SwiftUI

/// Lists H10 devices seen nearby. `onPick` receives the chosen H10 ID.
struct ScanSheet: View {
    @Environment(Roster.self) private var roster
    @Environment(AppSettings.self) private var settings
    @Environment(DeviceProviders.self) private var providers
    @Environment(\.dismiss) private var dismiss
    @State private var found: [String] = []

    let actionTitle: String
    let dismissOnPick: Bool
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(found, id: \.self) { id in
                    HStack {
                        Text(Format.device(id, short: false)).monospaced()
                        Spacer()
                        if !dismissOnPick, roster.devices.contains(id) {
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                        } else {
                            Button(actionTitle) {
                                onPick(id)
                                if dismissOnPick { dismiss() }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                if found.isEmpty { HStack { ProgressView(); Text("Searching for devices…").foregroundStyle(.secondary) } }
            }
            .navigationTitle("Nearby devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(dismissOnPick ? "Cancel" : "Done") { dismiss() } }
        }
        .task {
            for await id in providers.provider(includeSimulated: settings.useSimulator).scan() where !found.contains(id) {
                found.append(id)
            }
        }
    }
}
