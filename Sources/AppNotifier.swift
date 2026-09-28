import Foundation
import UserNotifications

/// Posts user-facing notifications.
///
/// Uses UNUserNotificationCenter when the process runs from a real app
/// bundle. For unbundled dev builds (`swift run Murmur`) the framework
/// crashes on access (no bundle proxy), and the legacy NSUserNotification
/// path it replaces silently dropped everything — so those builds log to
/// the console instead, which is at least visible in the dev terminal.
enum AppNotifier {
    // Must test for a real .app bundle. The dev binary embeds Info.plist via
    // -sectcreate (needed for the system-audio permission prompt), so
    // `bundleIdentifier` is non-nil under `swift run` too — and that sent dev
    // builds down the UNUserNotificationCenter path this split exists to
    // avoid. Same rule as SecretsStore.
    private static let isBundled = Bundle.main.bundlePath.hasSuffix(".app")
    private static let authorizationLock = NSLock()
    private static var didRequestAuthorization = false

    /// Call once at app launch (bundled builds) so the first real
    /// notification isn't swallowed while authorization is pending.
    static func requestAuthorizationIfNeeded() {
        guard isBundled else { return }
        // `notify` is called from background queues (HTTP routes, capture
        // callbacks), so the once-only flag needs a lock.
        authorizationLock.lock()
        let alreadyAsked = didRequestAuthorization
        didRequestAuthorization = true
        authorizationLock.unlock()
        guard !alreadyAsked else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("Notifications: authorization error: \(error.localizedDescription)")
            } else if !granted {
                NSLog("Notifications: permission denied — alerts will only appear in the console")
            }
        }
    }

    static func notify(title: String, body: String) {
        guard isBundled else {
            NSLog("🔔 \(title): \(body)")
            return
        }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Notifications: delivery failed: \(error.localizedDescription)")
            }
        }
    }
}
