import SwiftUI

/// Recording view for experimental conditions: a thin strip to keep an eye on every signal, big label buttons,
/// and a clip timeline of what was labelled when. Fits the screen without scrolling up to 12 labels.
struct LabelPanel: View {
    let slots: [Slot]

    var body: some View {
        VStack(spacing: Theme.gap) {
            SignalStrip(slots: slots)
            LabelButtons().frame(maxHeight: .infinity, alignment: .top)
            LabelClips()
        }
    }
}

/// One line per participant: tiny ECG, HR, and a warning icon when the signal needs attention.
private struct SignalStrip: View {
    @Environment(RecordingController.self) private var recording
    @Environment(Roster.self) private var roster
    let slots: [Slot]

    var body: some View {
        let columns = slots.count > 3 ? 2 : 1
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gap), count: columns), spacing: 6) {
            ForEach(slots) { row($0, compact: columns > 1) }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func row(_ slot: Slot, compact: Bool) -> some View {
        let name = recording.name(of: slot)
        let ok = slot.isStreaming && slot.noisySince == nil
        return HStack(spacing: 6) {
            ParticipantDot(color: roster.color(for: name), size: 8)
            if !compact { Text(name).font(.caption).lineLimit(1).frame(width: 64, alignment: .leading) }
            ECGWave(buffer: recording.buffers[slot.id], active: slot.isStreaming, seconds: 4, lineWidth: 1,
                    showsMessage: false, color: Theme.ecg(simulated: recording.isSimulated(slot)))
                .frame(height: 20)
            Text(slot.isStreaming ? "\(slot.hr)" : "–").font(.caption.monospacedDigit()).frame(width: 26, alignment: .trailing)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(ok ? .green : .orange)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(ok ? "signal OK" : ConnectionAdvisor.device(slot, now: .now)?.title ?? slot.state.label)")
    }
}

/// All labels at a glance, plus End. One tap marks the moment.
private struct LabelButtons: View {
    @Environment(RecordingController.self) private var recording
    @Environment(Roster.self) private var roster

    var body: some View {
        let count = roster.labels.count + 1
        let columns = count <= 6 ? 2 : 3
        let height: CGFloat = count <= 6 ? 64 : 52
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                ForEach(roster.labels) { label in
                    labelButton(label.name, color: Palette.label(label.colorIndex), height: height)
                }
                endButton(height: height)
            }
            if roster.labels.isEmpty {
                Text("Add labels in Settings > Labels.").font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .sensoryFeedback(.impact(weight: .medium), trigger: recording.labelEvents.count)
    }

    private func labelButton(_ name: String, color: Color, height: CGFloat) -> some View {
        let active = recording.activeLabel?.name == name
        return Button { recording.startLabel(name) } label: {
            Text(name)
                .font(.headline).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(active ? .white : .primary)
                .background(active ? color : color.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color, lineWidth: active ? 0 : 1.5)
                }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(name)
        .accessibilityHint(active ? "Running" : "Starts this condition")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func endButton(height: CGFloat) -> some View {
        Button(action: recording.endLabel) {
            Label("End", systemImage: "stop.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(.secondary)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .disabled(recording.activeLabel == nil)
        .accessibilityHint("Ends the running condition")
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The recording so far as a single track of coloured clips, like a video editor. Gaps are time without a label.
private struct LabelClips: View {
    @Environment(RecordingController.self) private var recording
    @Environment(Roster.self) private var roster

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date.timeIntervalSince1970
            let start = recording.startedAt?.timeIntervalSince1970 ?? now
            let spans = LabelTimeline.spans(recording.labelEvents, until: now)
            VStack(alignment: .leading, spacing: 8) {
                header(now: now)
                Canvas { g, size in draw(&g, size: size, spans: spans, start: start, now: now) }
                    .frame(height: 34)
                    .accessibilityElement()
                    .accessibilityLabel(summary(spans))
                HStack {
                    Text("0:00")
                    Spacer()
                    Text(Format.elapsed(now - start))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func header(now: Double) -> some View {
        HStack {
            if let active = recording.activeLabel {
                ParticipantDot(color: roster.labelColor(for: active.name), size: 8)
                Text(active.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(Format.elapsed(max(0, now - active.t))).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text(recording.labelEvents.isEmpty ? "Tap a label when a condition starts" : "No label running")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let until = recording.undoUntil, until.timeIntervalSince1970 > now {
                Button("Undo", systemImage: "arrow.uturn.backward", action: recording.undoLabel)
                    .font(.subheadline)
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    .accessibilityLabel("Undo last label")
            }
        }
        .frame(minHeight: 28)
    }

    /// The axis grows with the recording (at least a minute), so the whole session is always in view.
    private func draw(_ g: inout GraphicsContext, size: CGSize, spans: [LabelSpan], start: Double, now: Double) {
        let total = max(now - start, 60)
        func x(_ t: Double) -> CGFloat { size.width * CGFloat(min(max((t - start) / total, 0), 1)) }
        g.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Color(.tertiarySystemFill)))
        for span in spans {
            let rect = CGRect(x: x(span.start), y: 0, width: max(x(span.end) - x(span.start) - 1, 2), height: size.height)
            g.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(roster.labelColor(for: span.name)))
            let text = g.resolve(Text(span.name).font(.caption2.weight(.semibold)).foregroundStyle(.white))
            if text.measure(in: size).width + 8 < rect.width {
                g.draw(text, at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
            }
        }
        var line = Path()
        line.move(to: CGPoint(x: x(now) - 1, y: -2))
        line.addLine(to: CGPoint(x: x(now) - 1, y: size.height + 2))
        g.stroke(line, with: .color(.primary), lineWidth: 2)
    }

    private func summary(_ spans: [LabelSpan]) -> String {
        spans.isEmpty ? "No labels yet" : spans.map(\.name).joined(separator: ", then ")
    }
}
