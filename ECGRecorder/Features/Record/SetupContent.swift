import SwiftUI

/// Participant-device pairs and the recording name. Devices connect on their own while this is showing.
struct SetupContent: View {
    @Environment(RecordingController.self) private var recording
    @Environment(Roster.self) private var roster
    @State private var creatingForSlot: UUID?
    @State private var showNewParticipant = false
    @State private var scanSlot: UUID?
    @State private var didAutoScan = false
    @State private var pickingPrediction = false
    @State private var previewSlot: UUID?

    var body: some View {
        @Bindable var recording = recording
        List {
            ForEach(recording.slots) { slot in
                ParticipantCard(slot: slot,
                                onNewParticipant: { creatingForSlot = slot.id; showNewParticipant = true },
                                onScan: { scanSlot = slot.id },
                                onPreview: { previewSlot = slot.id })
                    .row()
                    .swipeActions(edge: .trailing) {
                        if recording.slots.count > 1 {
                            Button(role: .destructive) { recording.removeSlot(slot.id) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
            }
            if recording.canAddSlot { addButton.row() }
            nameField.row().padding(.top, 8)
            autoStopField.row()
            skipFirstField.row()
            if recording.canPredict { predictionField.row() }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .onAppear { recording.ensureFirstSlot() }
        .task { autoScanIfNoDevices() }
        .sheet(isPresented: Binding(isPresent: $scanSlot)) {
            if let slot = scanSlot {
                ScanSheet(actionTitle: "Use", dismissOnPick: true) { recording.useScanned(device: $0, for: slot) }
            }
        }
        .sheet(isPresented: Binding(isPresent: $previewSlot)) {
            if let id = previewSlot { PreviewSheet(slotID: id) }
        }
        .newParticipantAlert(isPresented: $showNewParticipant) { participant in
            if let slot = creatingForSlot { recording.assign(participant: participant.id, to: slot) }
        }
    }

    private var addButton: some View {
        Button { recording.addSlot() } label: {
            Label("Add participant", systemImage: "plus.circle.fill").frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    private var nameField: some View {
        @Bindable var recording = recording
        return VStack(alignment: .leading, spacing: 6) {
            Text("Recording name").font(.footnote).foregroundStyle(.secondary).padding(.leading, 4)
            HStack {
                TextField(recording.defaultTag, text: $recording.tag)
                    .submitLabel(.done)
                if !roster.tags.isEmpty {
                    Menu {
                        ForEach(roster.tags, id: \.self) { tag in Button(tag) { recording.tag = tag } }
                    } label: { Image(systemName: "tag") }
                }
            }
            .card()
        }
    }

    private var autoStopField: some View {
        @Bindable var recording = recording
        return HStack {
            Text("Stop after")
            Spacer()
            Picker("", selection: $recording.autoStopSeconds) {
                ForEach(Self.autoStopPresets, id: \.self) { Text(Format.elapsed(TimeInterval($0))).tag($0) }
            }
            .pickerStyle(.menu)
            .disabled(!recording.autoStopEnabled)
            .opacity(recording.autoStopEnabled ? 1 : 0.4)
            Toggle("", isOn: $recording.autoStopEnabled.animation()).labelsHidden()
        }
        .card()
    }

    private var skipFirstField: some View {
        @Bindable var recording = recording
        return HStack {
            Text("Skip first")
            Spacer()
            Picker("", selection: $recording.skipFirstSeconds) {
                ForEach(Self.skipFirstPresets, id: \.self) { Text("\($0) s").tag($0) }
            }
            .pickerStyle(.menu)
            .disabled(!recording.skipFirstEnabled)
            .opacity(recording.skipFirstEnabled ? 1 : 0.4)
            Toggle("", isOn: $recording.skipFirstEnabled.animation()).labelsHidden()
        }
        .card()
    }

    /// A 1-300 range is too long for a menu, so the value opens a small wheel instead.
    private var predictionField: some View {
        @Bindable var recording = recording
        return HStack {
            Text("Predicted RMSSD")
            Spacer()
            Button { pickingPrediction = true } label: {
                Text("\(recording.predictedRMSSD) ms").monospacedDigit()
            }
            .disabled(!recording.predictionEnabled)
            .opacity(recording.predictionEnabled ? 1 : 0.4)
            .accessibilityLabel("Predicted RMSSD, \(recording.predictedRMSSD) milliseconds")
            .popover(isPresented: $pickingPrediction) {
                Picker("Predicted RMSSD", selection: $recording.predictedRMSSD) {
                    ForEach(Self.predictionRange, id: \.self) { Text("\($0) ms").tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(width: 180, height: 180)
                .presentationCompactAdaptation(.popover)
            }
            Toggle("", isOn: $recording.predictionEnabled.animation()).labelsHidden()
        }
        .card()
    }

    private static let predictionRange = Array(stride(from: 10, through: 300, by: 10))
    private static let skipFirstPresets = [5, 10, 15, 20, 30, 45, 60, 90, 120]
    private static let autoStopPresets = [60, 120, 180, 240, 300, 360, 480, 600, 900, 1200, 1800, 2700, 3600]

    /// First run with no saved devices: go straight to scanning.
    private func autoScanIfNoDevices() {
        recording.ensureFirstSlot()
        guard !didAutoScan, roster.devices.isEmpty, let first = recording.slots.first, first.deviceID == nil else { return }
        didAutoScan = true
        scanSlot = first.id
    }
}

private extension View {
    /// A card sitting in a list row: no separator, no row background, even spacing.
    func row() -> some View {
        listRowInsets(EdgeInsets(top: Theme.gap / 2, leading: 0, bottom: Theme.gap / 2, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// The recording-size live view for one device while setting up, to check the signal before recording.
private struct PreviewSheet: View {
    @Environment(RecordingController.self) private var recording
    let slotID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Label("Preview · not recording", systemImage: "eye")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            // Looked up on every update so the numbers stay live; gone if the pair was removed meanwhile.
            if let slot = recording.slots.first(where: { $0.id == slotID }) {
                LiveTile(slot: slot, style: .full)
            }
        }
        .padding(Theme.screenPadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
