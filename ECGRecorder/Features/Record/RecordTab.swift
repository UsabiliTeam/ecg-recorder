import SwiftUI

/// One screen for the whole flow: set up pairs (devices stream live), record, stop. Only the content changes.
struct RecordTab: View {
    @Environment(RecordingController.self) private var recording
    @Environment(Roster.self) private var roster
    @Environment(SessionLibrary.self) private var library
    @Environment(BluetoothMonitor.self) private var bluetooth
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var isSetup: Bool { recording.phase == .setup }

    var body: some View {
        @Bindable var recording = recording
        VStack(spacing: Theme.gap) {
            header
            notices
            Group {
                if isSetup { SetupContent() } else { TileGrid(slots: recording.slots) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
            if recording.phase == .recording { MarkerBar().transition(.opacity) }
            RecordBar()
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 8)
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .top) { toast }
        .animation(.smooth(duration: 0.3), value: recording.phase)
        .animation(.default, value: recording.banner)
        .onChange(of: recording.phoneProblem) { _, problem in recording.phoneProblemChanged(problem) }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .alert("Recording saved", isPresented: Binding(isPresent: $recording.lastSaved), presenting: recording.lastSaved) { _ in
            Button("OK", role: .cancel) {}
        } message: { session in
            Text("\(session.title) · \(Format.duration(session.duration)) · \(session.participants.count) participant(s)\n\(session.fileName)"
                 + (Format.predictionSummary(session).map { "\n\n\($0)" } ?? ""))
        }
        .alert(recording.notice?.title ?? "", isPresented: Binding(isPresent: $recording.notice)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recording.notice?.message ?? "")
        }
    }

    /// Screen title while setting up, the running clock while recording.
    private var header: some View {
        HStack {
            if let start = recording.startedAt {
                VStack(alignment: .leading, spacing: 0) {
                    Text(recording.recordingName).font(.headline).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Group {
                            if let stopAt = recording.autoStopAt {
                                Text("\(Format.elapsed(max(0, stopAt.timeIntervalSince(ctx.date)))) left")
                                    .accessibilityLabel("Time until it stops")
                            } else {
                                Text(Format.liveClock(ctx.date.timeIntervalSince(start)))
                                    .accessibilityLabel("Recording time")
                            }
                        }
                        .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            } else {
                Text("Record").font(.largeTitle.bold())
                Spacer()
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var notices: some View {
        if let problem = recording.phoneProblem {
            ProblemBanner(problem: problem, onFix: bluetooth.openSettings)
        }
        if lowPower {
            ProblemBanner(problem: Problem(severity: .warning, title: "Low Power Mode is on",
                                           hint: "Turn it off so recording isn't throttled.", fix: nil))
        }
        if isSetup, library.lowStorage { StorageWarning().frame(maxWidth: .infinity, alignment: .leading) }
    }

    @ViewBuilder
    private var toast: some View {
        if let banner = recording.banner {
            Label(banner, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .padding(12).frame(maxWidth: .infinity)
                .background(.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white).padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
