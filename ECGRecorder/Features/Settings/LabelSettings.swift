import SwiftUI

/// Condition labels shown as buttons in the recording's label panel.
struct LabelsSettings: View {
    @Environment(Roster.self) private var roster
    @State private var editing: LabelDraft?
    @State private var editMode = EditMode.inactive

    var body: some View {
        List {
            Section {
                ForEach(roster.labels) { label in
                    Button { editing = LabelDraft(label) } label: {
                        HStack(spacing: 12) {
                            ParticipantDot(color: Palette.label(label.colorIndex), size: 12)
                            Text(label.name).foregroundStyle(.primary)
                        }
                    }
                }
                .onDelete { roster.removeLabels(at: $0) }
                .onMove { roster.moveLabels(from: $0, to: $1) }
            } footer: {
                Text("While recording, tap a label to mark when its condition starts. End closes it. Recordings keep the names they were made with.")
            }
        }
        .navigationTitle("Labels")
        .environment(\.editMode, $editMode)
        .toolbar {
            Button(editMode.isEditing ? "Done" : "Reorder") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
            .disabled(roster.labels.count < 2 && !editMode.isEditing)
            Button { editing = LabelDraft(colorIndex: roster.nextLabelColor) } label: { Image(systemName: "plus") }
                .disabled(roster.labels.count >= ConditionLabel.maxCount)
                .accessibilityLabel("Add label")
        }
        .sheet(item: $editing) { LabelEditor(draft: $0) }
    }
}

struct LabelDraft: Identifiable {
    let id = UUID()
    /// Nil for a new label.
    var labelID: UUID?
    var name = ""
    var colorIndex: Int

    init(_ label: ConditionLabel) {
        labelID = label.id
        name = label.name
        colorIndex = label.colorIndex
    }

    init(colorIndex: Int) { self.colorIndex = colorIndex }
}

private struct LabelEditor: View {
    @Environment(Roster.self) private var roster
    @Environment(\.dismiss) private var dismiss
    @State var draft: LabelDraft
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Baseline", text: $draft.name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section("Colour") { swatches }
            }
            .navigationTitle(draft.labelID == nil ? "New label" : "Edit label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = draft.labelID == nil }
        }
        .presentationDetents([.medium, .large])
    }

    private var swatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
            ForEach(Palette.labels.indices, id: \.self) { i in
                Button { draft.colorIndex = i } label: {
                    Circle().fill(Palette.labels[i]).frame(width: 34, height: 34)
                        .overlay {
                            if i == draft.colorIndex { Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(i + 1)")
                .accessibilityAddTraits(i == draft.colorIndex ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }

    private func save() {
        do {
            if let id = draft.labelID {
                try roster.updateLabel(id, name: draft.name, colorIndex: draft.colorIndex)
            } else {
                try roster.addLabel(draft.name, colorIndex: draft.colorIndex)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
