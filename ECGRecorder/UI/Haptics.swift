import AudioToolbox
import UIKit

/// Feedback the user can feel. Generators are kept and prepared so the tap is immediate.
@MainActor
enum Haptics {
    private static let notification = UINotificationFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    static func prepare() {
        notification.prepare()
        impact.prepare()
        rigid.prepare()
    }

    static func success() { notification.notificationOccurred(.success) }
    static func warning() { notification.notificationOccurred(.warning) }
    /// A firm tap for the start of a recording.
    static func start() { impact.impactOccurred() }
    /// Three full vibrations, in step with the bell's three strikes, for a timed recording stopping itself.
    /// Uses the vibration motor directly rather than a feedback generator: generator taps are too faint to
    /// notice with the phone on a desk, and iOS mutes them when System Haptics is off.
    static func autoStopped() {
        Task {
            for i in 0..<3 {
                if i > 0 { try? await Task.sleep(for: .milliseconds(450)) }
                AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
            }
        }
    }
}
