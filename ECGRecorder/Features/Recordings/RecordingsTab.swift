import SwiftUI

/// Browse recorded data: by recording, or by participant over days.
struct RecordingsTab: View {
    private enum Mode: String, CaseIterable { case recordings = "Recordings", participants = "Participants" }
    @State private var mode = Mode.recordings

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .bottom])
                switch mode {
                case .recordings: SessionsList()
                case .participants: ParticipantsList()
                }
            }
            .navigationTitle("Recordings")
        }
    }
}

private struct ParticipantsList: View {
    @Environment(Roster.self) private var roster

    var body: some View {
        List(roster.participants) { p in
            NavigationLink { ParticipantTimelineView(participant: p) } label: {
                HStack(spacing: 10) {
                    ParticipantDot(color: roster.color(for: p.pseudonym))
                    Text(p.pseudonym)
                }
            }
        }
        .overlay {
            if roster.participants.isEmpty {
                ContentUnavailableView("No participants", systemImage: "person.2",
                                       description: Text("Add participants in Settings or when recording."))
            }
        }
    }
}
