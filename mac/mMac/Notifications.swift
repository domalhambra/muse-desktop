import AppKit
import MuseBackend
import MuseKit
import Observation
import os
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
  /// Why the last permission request failed, when it failed rather than being refused.
  /// `AppearancePane` shows it in place of the System Settings note.
  private(set) var lastError: String?

  private nonisolated static let log = Logger(subsystem: "com.domalhambra.mmac", category: "notifications")

  /// System Settings › Notifications.
  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

  override init() {
    super.init()
    // Set before launch ends, so a click that launches mMac still reaches the delegate.
    UNUserNotificationCenter.current().delegate = self
  }

  /// Asks macOS once; later calls return the saved answer. An error is not a refusal: it sets
  /// `lastError`, leaves `denied` as it was, and returns false.
  func requestPermission() async -> Bool {
    do {
      let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
      denied = !granted
      lastError = nil
      return granted
    } catch {
      lastError = "mMac could not ask macOS for notification permission: \(error.localizedDescription)"
      return false
    }
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
    // Logs only the error: the body is the conversation's name or title.
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: session.sessionId, content: content, trigger: nil)
    ) { error in
      if let error {
        Self.log.error("Could not post a completion notification: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// A scheduled run's notice. The identifier is the session id, as `post(for:)` uses.
  func postScheduled(name: String, session: Session) {
    let content = UNMutableNotificationContent()
    content.title = ScheduleRules.finishedNotice(name: name)
    content.body = CompletionNotice.content(for: session).body
    content.sound = .default
    content.userInfo = ["sessionId": session.sessionId]
    // Logs only the error: the title and body name the task and the conversation.
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: session.sessionId, content: content, trigger: nil)
    ) { error in
      if let error {
        Self.log.error("Could not post a scheduled-task notification: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// A click on a notification. macOS calls it off the main actor.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let sessionId = response.notification.request.content.userInfo["sessionId"] as? String else { return }
    await MainActor.run { openConversation?(sessionId) }
  }
}
