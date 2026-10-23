import SwiftUI

/// One participant's live numbers and ECG while recording. The trace is short and wide, so it covers more time.
struct LiveTile: View {
    @Environment(RecordingController.self) private var recording
    @Environment(AppSettings.self) private var settings
    @Environment(Roster.self) private var roster
    let slot: Slot
    let style: TileStyle

    private var name: String { recording.name(of: slot) }
    private var hr: String { slot.isStreaming ? "\(slot.hr)" : "–" }
    private var rmssd: String { slot.isStreaming ? slot.rmssd.map { String(format: "%.0f", $0) } ?? "–" : "–" }
    private var zone: String { slot.isStreaming ? "\(HRZone.zone(hr: slot.hr))" : "–" }
    private var wave: some View {
        ECGWave(buffer: recording.buffers[slot.id], active: slot.isStreaming,
                seconds: style == .full ? 6 : 5, lineWidth: style == .compact ? 1.2 : 1.5, showsMessage: style != .compact,
                color: Theme.ecg(simulated: recording.isSimulated(slot)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
        .overlay {
            if !slot.hasStreamed {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.orange, lineWidth: 1.5)
            }
        }
        .contextMenu {
            if recording.isSimulated(slot) {
                Button("Simulate disconnect") { recording.simulateFault(slot.id, noData: false) }
                Button("Simulate no data") { recording.simulateFault(slot.id, noData: true) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ParticipantDot(color: roster.color(for: name))
            Text(name).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            if !slot.hasStreamed { notRecordingBadge } else if !slot.isStreaming || slot.noisySince != nil { problemText }
        }
    }

    /// Persistent while a device has never connected in this recording; its participant is named in the header.
    private var notRecordingBadge: some View {
        Label("Not recording", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold)).foregroundStyle(.orange).labelStyle(.titleAndIcon)
    }

    /// Only shown when the device isn't streaming or the signal is noisy; a healthy trace needs no label.
    private var problemText: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let problem = ConnectionAdvisor.device(slot, now: ctx.date)
            Text(problem?.title ?? (slot.isStreaming ? "" : slot.state.label)).font(.caption).foregroundStyle(problem == nil ? Color.secondary : Color.orange)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .full:
            wave.frame(height: 140)
            HStack(alignment: .top, spacing: 28) {
                metric("HR", hr, "bpm", size: 40)
                metric("RMSSD", rmssd, "ms", size: 40)
                if settings.zonesEnabled { metric("Zone", zone, "", size: 40, tint: zoneColor) }
            }
        case .medium:
            HStack(spacing: 16) {
                wave.frame(height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    metric("HR", hr, "bpm", size: 26)
                    metric("RMSSD", rmssd, "ms", size: 26)
                }.frame(width: 120, alignment: .leading)
            }
        case .compact:
            wave.frame(height: 34)
            HStack(alignment: .firstTextBaseline) {
                metric("HR", hr, "bpm", size: 28)
                Spacer(minLength: 0)
                metric("RMSSD", rmssd, "ms", size: 16)
            }
        }
    }

    private var zoneColor: Color { slot.isStreaming ? HRZone.level(zone: HRZone.zone(hr: slot.hr)).color : .primary }

    private func metric(_ label: String, _ value: String, _ unit: String, size: CGFloat, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tint).minimumScaleFactor(0.5).lineLimit(1)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
