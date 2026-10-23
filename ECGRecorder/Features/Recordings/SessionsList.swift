import SwiftUI

struct SessionsList: View {
    @Environment(SessionLibrary.self) private var library
    @State private var toDelete: Session?
    @State private var selection = Set<UUID>()
    @State private var editMode = EditMode.inactive
    @State private var confirmBulkDelete = false

    private var shareItems: [SessionFile] { selected.map { SessionFile(url: library.csvURL($0)) } }

    /// Share on the left, Delete on the right, and the full count between them.
    private var bulkBar: some View {
        HStack {
            ShareLink(items: shareItems, preview: { SharePreview($0.url.lastPathComponent) }) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(selection.isEmpty)
            Spacer()
            Text(selection.isEmpty ? "Select recordings" : "\(selection.count) selected")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).fixedSize()
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive) { confirmBulkDelete = true }
                .disabled(selection.isEmpty)
        }
        .padding(.horizontal, Theme.screenPadding).padding(.vertical, 12)
        .background(.bar)
    }

    private var selected: [Session] { library.sessions.filter { selection.contains($0.id) } }

    var body: some View {
        list
            .environment(\.editMode, $editMode)
            .onChange(of: editMode) { if !editMode.isEditing { selection = [] } }
            .toolbar { toolbarContent }
            .toolbar(editMode.isEditing ? .hidden : .visible, for: .tabBar)
            .safeAreaInset(edge: .bottom) { if editMode.isEditing { bulkBar } }
            .overlay { emptyState }
            .alert("Delete \(selection.count) recording(s)?", isPresented: $confirmBulkDelete) {
                Button("Delete", role: .destructive, action: deleteSelected)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The CSVs and their index entries are removed. This can't be undone.")
            }
            .alert("Delete this recording?", isPresented: Binding(isPresent: $toDelete), presenting: toDelete) { session in
                Button("Delete", role: .destructive) { library.delete(session) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The CSV and its index entries are removed. This can't be undone.")
            }
    }

    private var list: some View {
        List(selection: $selection) {
            if library.lowStorage { StorageWarning() }
            ForEach(library.sessions) { session in row(session) }
        }
    }

    private func row(_ session: Session) -> some View {
        NavigationLink { SessionDetailView(session: session) } label: { SessionRow(session: session) }
            .contextMenu { menu(for: session) }
            .swipeActions {
                Button(role: .destructive) { toDelete = session } label: { Label("Delete", systemImage: "trash") }
            }
    }

    @ViewBuilder
    private func menu(for session: Session) -> some View {
        ShareLink(item: SessionFile(url: library.csvURL(session)), preview: SharePreview(session.fileName)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button("Open in Files", systemImage: "folder") {
            if let url = URL(string: "shareddocuments://") { UIApplication.shared.open(url) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { toDelete = session }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if !library.sessions.isEmpty {
                Button(editMode.isEditing ? "Done" : "Select") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.sessions.isEmpty {
            ContentUnavailableView("No recordings", systemImage: "tray", description: Text("Recordings appear here."))
        }
    }

    private func deleteSelected() {
        selected.forEach(library.delete)
        selection = []
        editMode = .inactive
    }
}

private struct SessionRow: View {
    @Environment(Roster.self) private var roster
    let session: Session

    private var averages: String? {
        guard session.participants.count == 1 else { return nil }
        var parts: [String] = []
        if let hr = session.avgHR { parts.append("avg \(String(format: "%.0f", hr)) bpm") }
        if let rmssd = session.avgRMSSD { parts.append("RMSSD \(String(format: "%.0f", rmssd)) ms") }
        if let guess = session.predictedRMSSD { parts.append("guessed \(guess) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.headline)
            Text(session.subtitle).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(session.participants, id: \.self) { name in
                    HStack(spacing: 5) {
                        ParticipantDot(color: roster.color(for: name), size: 8)
                        Text(name).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let averages { Text(averages).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

/// All participants of one recording on a shared time axis, in minutes since the start.
/// HR first, RMSSD second; other graphs can be added.
struct SessionDetailView: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(Roster.self) private var roster
    let session: Session
    @State private var traces: [String: [IndexPoint]]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(session.subtitle).font(.footnote).foregroundStyle(.secondary)
                if let traces {
                    MetricStack(defaults: Metric.recordingDefaults, optional: Metric.recordingOptional) { metric in
                        chart(metric, traces: traces)
                    }
                    if let labels = session.labels { labelList(labels) }
                    if let markers = session.markers { markerList(markers) }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }.padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: SessionFile(url: library.csvURL(session)), preview: SharePreview(session.fileName))
        }
        .task { traces = await library.traces(for: session) }
    }

    @ViewBuilder
    private func chart(_ metric: Metric, traces: [String: [IndexPoint]]) -> some View {
        let points = ChartData.points(traces, metric: metric)
        if points.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(metric.title) (\(metric.unit))").font(.headline)
                Text("No values yet. Trends need about a minute of data.").font(.footnote).foregroundStyle(.secondary)
            }.card()
        } else {
            MetricChart(title: "\(metric.title) (\(metric.unit))", points: points,
                        domain: session.start...session.start.addingTimeInterval(max(session.duration, 60)),
                        colors: Dictionary(uniqueKeysWithValues: session.participants.map { ($0, roster.color(for: $0)) }),
                        xValues: .automatic(desiredCount: 4),
                        xLabel: { Format.elapsed($0.timeIntervalSince(session.start)) },
                        markers: session.markers ?? [], labels: session.labels ?? [],
                        labelColor: roster.labelColor(for:))
        }
    }

    /// Each labelled stretch: start and end since the recording began, and how long it lasted.
    private func labelList(_ labels: [LabelSpan]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Labels").font(.headline)
            ForEach(Array(labels.enumerated()), id: \.offset) { _, span in
                let from = span.start - session.start.timeIntervalSince1970
                HStack(spacing: 8) {
                    ParticipantDot(color: roster.labelColor(for: span.name), size: 8)
                    Text(span.name).lineLimit(1)
                    Spacer()
                    Text("\(Format.elapsed(from))–\(Format.elapsed(from + span.end - span.start))")
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }

    private func markerList(_ markers: [EventMarker]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Events").font(.headline)
            ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                LabeledContent(marker.name,
                               value: Format.elapsed(Date(timeIntervalSince1970: marker.t).timeIntervalSince(session.start)))
                    .monospacedDigit()
            }
        }
        .card()
    }
}
