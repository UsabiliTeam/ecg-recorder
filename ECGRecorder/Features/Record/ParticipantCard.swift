import SwiftUI

/// One participant-device pair while setting up. A tiny live ECG in the middle shows whether the device streams.
struct ParticipantCard: View {
    @Environment(RecordingController.self) private var recording
    @Environment(Roster.self) private var roster
    let slot: Slot
    let onNewParticipant: () -> Void
    let onScan: () -> Void
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                participantMenu
                Spacer(minLength: 8)
                Button(action: onPreview) {
                    ECGWave(buffer: recording.buffers[slot.id], active: slot.isStreaming, seconds: 4, lineWidth: 1.2,
                            showsMessage: false, color: Theme.ecg(simulated: recording.isSimulated(slot)))
                        .frame(width: 56, height: 30)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)   // a plain style keeps the rest of the list row from triggering it
                .padding(-8)
                .accessibilityLabel("Show larger live ECG")
                Spacer(minLength: 8)
                deviceMenu
            }
            StatusLine(slot: slot)
        }
        .card()
    }

    private var participantMenu: some View {
        Menu {
            ForEach(roster.participants) { p in
                Button(p.pseudonym) { recording.assign(participant: p.id, to: slot.id) }
                    .disabled(recording.isTaken(participant: p.id, except: slot.id))
            }
            Divider()
            Button("New participant…", action: onNewParticipant)
        } label: {
            let participant = roster.participant(slot.participantID)
            HStack(spacing: 8) {
                if let participant { ParticipantDot(color: roster.color(for: participant.pseudonym)) }
                dropdownLabel(participant?.pseudonym ?? "Participant", placeholder: participant == nil)
            }
        }
        .layoutPriority(1)
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(roster.devices, id: \.self) { d in
                Button(Format.device(d, short: false)) { recording.assign(device: d, to: slot.id) }
                    .disabled(recording.isTaken(device: d, except: slot.id))
            }
            if !roster.devices.isEmpty { Divider() }
            Button("Scan for devices…", systemImage: "dot.radiowaves.left.and.right", action: onScan)
        } label: {
            dropdownLabel(slot.deviceID.map { Format.device($0) } ?? "Device", placeholder: slot.deviceID == nil)
        }
        .layoutPriority(1)
    }

    private func dropdownLabel(_ text: String, placeholder: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1).foregroundStyle(placeholder ? Color.secondary : Color.accentColor)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .font(.body.weight(.medium))
    }
}

/// Link state as a sentence; when something is wrong, the diagnosis and what to try replace it.
struct StatusLine: View {
    let slot: Slot

    var body: some View {
        // Re-evaluated every second so the advice appears once a device has been quiet for long enough.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let problem = ConnectionAdvisor.device(slot, now: ctx.date)
            VStack(alignment: .leading, spacing: 2) {
                if let problem {
                    Text(problem.title).font(.footnote.weight(.semibold)).foregroundStyle(problem.severity == .blocking ? .red : .orange)
                    Text(problem.hint).font(.footnote).foregroundStyle(.secondary)
                } else {
                    if !slot.isStreaming {
                        Text(slot.deviceID == nil ? "Choose a device" : slot.state.label).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
