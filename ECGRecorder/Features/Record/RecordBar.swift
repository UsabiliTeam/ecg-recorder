import SwiftUI

/// The one big button: Record (with the reason when it can't be tapped) while idle, Stop while recording.
struct RecordBar: View {
    @Environment(RecordingController.self) private var recording
    @State private var confirmStop = false

    var body: some View {
        control
            .padding(.bottom, 4)
            .alert("Stop recording?", isPresented: $confirmStop) {
                Button("Stop", role: .destructive) { recording.stop() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The recording will be saved.")
            }
    }

    @ViewBuilder
    private var control: some View {
        switch recording.phase {
        case .setup:
            if let startingAt = recording.startingAt {
                Button {} label: {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("Starting in \(Format.elapsed(max(0, startingAt.timeIntervalSince(ctx.date))))")
                    }
                }
                .buttonStyle(BigButtonStyle())
                .disabled(true)
                .opacity(0.45)
            } else {
                Button { recording.start() } label: { Text(recording.readiness.title) }
                    .buttonStyle(BigButtonStyle())
                    .disabled(!recording.canStart)
                    .opacity(recording.canStart ? 1 : 0.45)
                    .contentTransition(.opacity)
            }
        case .recording:
            Button { confirmStop = true } label: { Text("Stop") }
                .buttonStyle(BigButtonStyle(tint: .red))
        case .saving:
            ProgressView().frame(maxWidth: .infinity, minHeight: Theme.buttonHeight)
        }
    }
}
