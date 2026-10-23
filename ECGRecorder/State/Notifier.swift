import UserNotifications

/// Lock-screen alerts. Sound and vibration follow iOS settings; Focus may suppress them.
enum Notifier {
    /// Lets notifications show as banners even while the app is open (used by the test alert).
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions { [.banner, .sound] }
    }

    private static let presenter = Presenter()

    /// Call once at launch: installs the delegate and asks for permission the first time.
    static func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// `after` delays delivery, so a test can be sent and the phone locked.
    static func post(_ body: String, after delay: TimeInterval? = nil, sound: UNNotificationSound? = .default) {
        let content = UNMutableNotificationContent()
        content.title = "ECG Recorder"
        content.body = body
        content.sound = sound
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
    }
}
