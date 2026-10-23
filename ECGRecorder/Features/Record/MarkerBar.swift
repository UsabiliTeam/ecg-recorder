import SwiftUI

/// "<event name> <Mark>" under the live tiles. Tap Mark to timestamp the moment in the file; tap the name to
/// rename the next event first. The name is set before marking so the tap itself is instant.
struct MarkerBar: View {
    @Environment(RecordingController.self) private var recording
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 12) {
            Button { draft = recording.markerName; renaming = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill").foregroundStyle(.tint)
                    Text(recording.nextMarkerName).lineLimit(1)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("Next event, \(recording.nextMarkerName)")
            .accessibilityHint("Renames it")
            Spacer(minLength: 8)
            if let last = recording.lastMarker {
                Text("\(last.name) ✓").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    .id(last.t)
                    .transition(.opacity)
            }
            Button("Mark", action: recording.mark)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Mark \(recording.nextMarkerName)")
        }
        .card()
        .animation(.default, value: recording.lastMarker)
        .sensoryFeedback(.impact(weight: .medium), trigger: recording.markerCount)
        .alert("Name the next event", isPresented: $renaming) {
            TextField(EventMarker.defaultName(recording.markerCount + 1), text: $draft)
            Button("Save") { recording.markerName = draft }
            Button("Cancel", role: .cancel) {}
        }
    }
}
