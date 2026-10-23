import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ECGRecorderWidgets: WidgetBundle {
    var body: some Widget { RecordingLiveActivity() }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(.black.opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        AppIconGlyph(size: 20)
                        Text(context.attributes.name).font(.headline).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let hr = context.state.hr { HeartRateBlock(state: context.state, hr: hr) } else { DeviceCount(state: context.state) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingClock(state: context.state, size: 28)
                }
            } compactLeading: {
                AppIconGlyph(size: 20)
            } compactTrailing: {
                if let hr = context.state.hr { Text("\(hr)").font(.body.monospacedDigit().weight(.semibold)) } else { DeviceCount(state: context.state) }
            } minimal: {
                DeviceCount(state: context.state)
            }
        }
    }
}

private struct LockScreenView: View {
    let attributes: RecordingActivityAttributes
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    AppIconGlyph(size: 20)
                    Text(attributes.name).font(.headline).lineLimit(1)
                }
                RecordingClock(state: state, size: 30)
            }
            Spacer()
            if let hr = state.hr {
                HeartRateBlock(state: state, hr: hr)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    DeviceCount(state: state).font(.title.weight(.semibold))
                    Text("devices").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

/// "5/5" in green while every device streams, red as soon as one is missing.
private struct DeviceCount: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Text("\(state.connected)/\(state.total)")
            .font(.system(.body, design: .rounded, weight: .semibold).monospacedDigit())
            .foregroundStyle(state.isComplete ? Color.green : Color.red)
            .accessibilityLabel("\(state.connected) of \(state.total) devices connected")
    }
}

/// The app icon, shown wherever the recorder used to show an ECG glyph.
private struct AppIconGlyph: View {
    let size: CGFloat

    var body: some View {
        Image("AppIconImage")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .frame(width: size, height: size)
    }
}

/// "Starting in" a countdown during Skip first, then counting up from the start, or down to the auto-stop
/// deadline. SwiftUI updates it by itself, so no push is sent every second. A countdown stops at 0:00
/// instead of running on past it.
private struct RecordingClock: View {
    let state: RecordingActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if state.startsAt != nil { Text("Starting in").font(.caption).foregroundStyle(.secondary) }
            clock
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder private var clock: some View {
        if let startsAt = state.startsAt {
            Text(timerInterval: Date.now...max(startsAt, .now), countsDown: true)
        } else if let end = state.autoStopAt, let start = state.startedAt {
            Text(timerInterval: start...max(end, start), countsDown: true)
        } else if let start = state.startedAt {
            Text(start, style: .timer)
        }
    }
}

/// One device: heart rate large, the zone as a coloured number, and the device count only when a device is missing.
private struct HeartRateBlock: View {
    let state: RecordingActivityAttributes.ContentState
    let hr: Int

    private var zoneColor: Color {
        switch state.zoneLevel {
        case .easy: .green
        case .moderate: .yellow
        case .hard: .red
        case nil: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(hr)").font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                Text("bpm").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let zone = state.zone {
                    Text("\(zone)").font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit()).foregroundStyle(zoneColor)
                }
                if !state.isComplete { DeviceCount(state: state).font(.caption) }
            }
        }
    }
}
