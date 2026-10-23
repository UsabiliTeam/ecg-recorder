import ActivityKit
import Foundation

/// Shows the recording on the lock screen and in the Dynamic Island. Best effort: failing to show it never affects recording.
@MainActor
final class LiveActivityController {
    typealias State = RecordingActivityAttributes.ContentState

    private var activity: Activity<RecordingActivityAttributes>?
    private var lastState: State?
    private var lastPush = Date.distantPast
    /// Heart rate changes every second; iOS limits how often an activity may update, so it is pushed this often at most.
    private static let minHeartRateInterval: TimeInterval = 5

    var isActive: Bool { activity != nil }

    /// Must be called while the app is in front: iOS refuses new activities from the background.
    func start(name: String, state: State) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: RecordingActivityAttributes(name: name),
                                         content: .init(state: state, staleDate: staleDate(state)))
        lastState = state
        lastPush = .now
    }

    /// Pushes right away when the device count, zone or clock changes, and at most every few seconds for heart rate alone.
    func update(_ state: State) {
        guard let activity, state != lastState else { return }
        let importantChange = state.connected != lastState?.connected || state.total != lastState?.total
            || state.zone != lastState?.zone || state.startsAt != lastState?.startsAt
            || state.startedAt != lastState?.startedAt || state.autoStopAt != lastState?.autoStopAt
        guard importantChange || Date.now.timeIntervalSince(lastPush) >= Self.minHeartRateInterval else { return }
        lastState = state
        lastPush = .now
        let content = ActivityContent(state: state, staleDate: staleDate(state))
        Task { await activity.update(content) }
    }

    /// Ends every activity of this app, including ones left behind by a previous run that iOS terminated,
    /// which would otherwise keep counting on the lock screen and use up the app's activity allowance.
    func end() {
        activity = nil
        lastState = nil
        let all = Activity<RecordingActivityAttributes>.activities
        guard !all.isEmpty else { return }
        Task { for a in all { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    /// Past the auto-stop deadline the recording should be over; if the app could not end the activity
    /// in time, iOS dims it rather than showing it as live.
    private func staleDate(_ state: State) -> Date? {
        state.autoStopAt?.addingTimeInterval(30)
    }
}
