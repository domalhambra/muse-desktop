import AppKit
import MuseBackend
import MuseKit
import Observation
@preconcurrency import UserNotifications

/// Completion notifications. Electron posts them from its main process; mMac posts them here.
/// Nothing here asks macOS for permission until the person turns the setting on in
/// `AppearancePane`.
@MainActor @Observable
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
  /// Opens a conversation when its notification is clicked. `AppController` sets it.
  @ObservationIgnored var openConversation: (@MainActor (String) -> Void)?
  /// macOS refused permission. `AppearancePane` then shows how to turn it on in System Settings.
  private(set) var denied = false

  /// System Settings › Notifications.
  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

  override init() {
    super.init()
    // Set before launch ends, so a click that launches mMac still reaches the delegate.
    UNUserNotificationCenter.current().delegate = self
  }

  /// Asks macOS once; later calls return the saved answer.
  func requestPermission() async -> Bool {
    let granted =
      (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    denied = !granted
    return granted
  }

  /// Reads the saved answer without asking, so a refusal made in System Settings shows too.
  func refresh() async {
    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    denied = status == .denied
  }

  /// Opens System Settings › Notifications.
  func openSystemSettings() {
    NSWorkspace.shared.open(Self.settingsURL)
  }

  /// Posts `CompletionNotice`'s content. The identifier is the session id, so a second notice for
  /// one conversation replaces the first.
  func post(for session: Session) {
    let notice = CompletionNotice.content(for: session)
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.body
    content.sound = .default
    content.userInfo = ["sessionId": session.sessionId]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: session.sessionId, content: content, trigger: nil))
  }

  /// A click on a notification. macOS calls it off the main actor.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let sessionId = response.notification.request.content.userInfo["sessionId"] as? String else { return }
    await MainActor.run { openConversation?(sessionId) }
  }
}
