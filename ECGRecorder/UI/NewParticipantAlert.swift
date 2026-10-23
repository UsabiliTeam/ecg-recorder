import SwiftUI

/// Alert to create a participant, shared by the Record screen and Settings.
private struct NewParticipantAlert: ViewModifier {
    @Environment(Roster.self) private var roster
    @Binding var isPresented: Bool
    let onCreated: (Participant) -> Void
    @State private var text = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert("New participant", isPresented: $isPresented) {
                TextField("Pseudonym", text: $text)
                Button("Cancel", role: .cancel) { text = "" }
                Button("Add", action: add)
            } message: {
                Text("The pseudonym is permanent.")
            }
            .alert("Can't add participant", isPresented: Binding(isPresent: $error)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    private func add() {
        do { onCreated(try roster.addParticipant(text)) } catch { self.error = error.localizedDescription }
        text = ""
    }
}

extension View {
    func newParticipantAlert(isPresented: Binding<Bool>, onCreated: @escaping (Participant) -> Void = { _ in }) -> some View {
        modifier(NewParticipantAlert(isPresented: isPresented, onCreated: onCreated))
    }
}
