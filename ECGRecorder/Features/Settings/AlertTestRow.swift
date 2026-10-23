import SwiftUI
import UserNotifications

/// Tests each alert channel and says why notifications don't arrive when iOS has them switched off.
struct AlertTestRow: View {
    @Environment(BluetoothMonitor.self) private var bluetooth
    @Environment(AppSettings.self) private var settings
    @State private var status: UNAuthorizationStatus?
    @State private var sent = false

    var body: some View {
        Button(sent ? "Sent. Lock the phone to see it." : "Send test alert", action: sendTest)
            .disabled(sent)
            .task { status = await Notifier.status() }
        if status == .denied {
            Label("Notifications are off for this app in iOS Settings.", systemImage: "bell.slash").font(.footnote).foregroundStyle(.orange)
            Button("Open iOS Settings", action: bluetooth.openSettings)
        }
    }

    private func sendTest() {
        Task {
            status = await Notifier.status()
            if settings.alertChannels.contains(.haptic) { Haptics.warning() }
            Notifier.post("Test alert: alerts are working.", after: 5)
            sent = true
            try? await Task.sleep(for: .seconds(6))
            sent = false
        }
    }
}
