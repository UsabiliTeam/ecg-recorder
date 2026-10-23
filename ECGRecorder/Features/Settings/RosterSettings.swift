import SwiftUI

struct ParticipantsSettings: View {
    @Environment(Roster.self) private var roster
    @State private var adding = false
    @State private var toDelete: Participant?

    var body: some View {
        List {
            Section {
                ForEach(roster.participants) { p in
                    Text(p.pseudonym).swipeActions {
                        Button(role: .destructive) { toDelete = p } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } footer: {
                Text("Removing a participant keeps their past sessions.")
            }
        }
        .navigationTitle("Participants")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .newParticipantAlert(isPresented: $adding)
        .alert("Delete participant?", isPresented: Binding(isPresent: $toDelete), presenting: toDelete) { p in
            Button("Delete", role: .destructive) { roster.removeParticipant(p.id) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("\(p.pseudonym) is removed from the phonebook. Past sessions are kept.")
        }
    }
}

struct DevicesSettings: View {
    @Environment(Roster.self) private var roster
    @State private var adding = false
    @State private var scanning = false
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        List {
            ForEach(roster.devices, id: \.self) { Text(Format.device($0, short: false)).monospaced() }
                .onDelete { roster.removeDevices(at: $0) }
        }
        .navigationTitle("Devices")
        .toolbar {
            Menu {
                Button("Scan for devices", systemImage: "dot.radiowaves.left.and.right") { scanning = true }
                Button("Enter ID", systemImage: "keyboard") { adding = true }
            } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $scanning) {
            ScanSheet(actionTitle: "Add", dismissOnPick: false) { try? roster.addDevice($0) }
        }
        .alert("Add device", isPresented: $adding) {
            TextField("Device ID", text: $text).textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Cancel", role: .cancel) { text = "" }
            Button("Add") {
                do { try roster.addDevice(text) } catch { self.error = error.localizedDescription }
                text = ""
            }
        }
        .alert("Can't add device", isPresented: Binding(isPresent: $error)) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}

struct TagsSettings: View {
    @Environment(Roster.self) private var roster
    @State private var text = ""

    var body: some View {
        List {
            Section {
                ForEach(roster.tags, id: \.self) { Text($0) }
                    .onDelete { roster.removeTags(at: $0) }
            }
            Section {
                HStack {
                    TextField("New tag", text: $text).onSubmit(add)
                    Button("Add", action: add).disabled(text.isEmpty)
                }
            }
        }
        .navigationTitle("Saved tags")
    }

    private func add() {
        roster.addTag(text)
        text = ""
    }
}
