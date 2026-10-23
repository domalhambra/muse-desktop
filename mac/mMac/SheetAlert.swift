import AppKit

/// Lets a caller close an alert that is still showing.
@MainActor
final class AlertToken {
  fileprivate var dismiss: (() -> Void)?
  /// Set by `close()`. An alert still waiting for a window then never shows.
  private(set) var isClosed = false
  /// Closes the alert, which then answers -1, or stops it showing if it has not shown yet.
  func close() {
    isClosed = true
    dismiss?()
  }
}

/// Alerts and open panels as sheets on mMac's window. An alert goes on top of any sheet already
/// open there, such as Rename, so an Ask that the rename starts still shows.
@MainActor
enum SheetAlert {
  /// The window a new sheet attaches to: the front-most sheet of the conversation window, short
  /// of an alert. With `preferringKey`, the key window's comes first, so an open panel started in
  /// the Settings window attaches there. While the conversation window is not showing, waits up
  /// to `limit` for it, since an Ask and the File menu open it first; then any window that can be
  /// main will do. Stops waiting when `token` is closed.
  static func host(
    waitingUpTo limit: Duration = .zero, token: AlertToken? = nil, preferringKey: Bool = false
  ) async -> NSWindow? {
    let deadline = ContinuousClock.now + limit
    while true {
      if let window = (preferringKey ? keyRoot() : nil)
        ?? NSApp.windows.first(where: { $0.isVisible && MMacApp.isMainWindow($0) })
      {
        return front(of: window)
      }
      if token?.isClosed == true { return nil }
      if ContinuousClock.now >= deadline {
        return (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }))
          .map(front(of:))
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  /// `window`'s front-most sheet, short of an alert. A sheet is itself a window, and can carry a
  /// sheet of its own. An alert's window is never a host: an open panel must not attach to an
  /// Ask, nor an Ask to another Ask.
  private static func front(of window: NSWindow) -> NSWindow {
    var front = window
    while let sheet = front.attachedSheet, !Self.isAlert(sheet) { front = sheet }
    return front
  }

  /// The window that holds the key window: the key window itself, or the window a key sheet is
  /// attached to. Nil for a window without a title bar, such as a popover's, and for an alert.
  private static func keyRoot() -> NSWindow? {
    guard var window = NSApp.keyWindow else { return nil }
    while let parent = window.sheetParent { window = parent }
    guard window.isVisible, window.styleMask.contains(.titled), !isAlert(window) else { return nil }
    return window
  }

  /// Whether `window` is an alert's window: one `present` is showing, or any other NSAlert, such
  /// as SwiftUI's `.alert`, whose panel class AppKit names `_NSAlertPanel`. The class name is
  /// private, so the set of mMac's own alerts does not depend on it.
  private static func isAlert(_ window: NSWindow) -> Bool {
    alertWindows.contains(ObjectIdentifier(window)) || window.className.contains("AlertPanel")
  }

  /// The windows of the alerts `present` is showing.
  private static var alertWindows: Set<ObjectIdentifier> = []

  /// Shows an alert and returns the chosen button's index, or -1 when it was closed through
  /// `token` or no window showed. The last button is the default and the cancel choice, as in
  /// every Electron dialog the Asks replace: Return and Escape both choose it. With
  /// `preferringKey`, the alert shows on the key window, so a confirmation the Settings window
  /// asks shows there.
  static func present(
    title: String, message: String, detail: String? = nil, buttons: [String], token: AlertToken? = nil,
    preferringKey: Bool = false
  ) async -> Int {
    guard !buttons.isEmpty,
      let window = await host(waitingUpTo: .seconds(1), token: token, preferringKey: preferringKey),
      token?.isClosed != true
    else { return -1 }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = [message, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    // NSAlert puts the first button it is given on the right and gives it Return. The last
    // button is the default, so they go in reverse, and read left to right in the Ask's order.
    for title in buttons.reversed() { alert.addButton(withTitle: title) }
    // NSAlert gives Escape only to a button titled Cancel. Escape always chooses the default here.
    for button in alert.buttons where button.keyEquivalent == "\u{1b}" { button.keyEquivalent = "" }
    let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
      guard event.keyCode == 53 else { return event }
      let eventWindow = event.window
      // Local monitors run on the main thread. `assumeIsolated` must return a Sendable value and
      // NSEvent is not, so it returns a Bool. The window and alert are captured freely only
      // because neither closure is `@Sendable`.
      let handled = MainActor.assumeIsolated { () -> Bool in
        guard let alert, eventWindow === alert.window else { return false }
        window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        return true
      }
      return handled ? nil : event
    }
    token?.dismiss = { [weak alert] in
      if let alert { window.endSheet(alert.window, returnCode: .abort) }
    }
    let alertWindow = ObjectIdentifier(alert.window)
    alertWindows.insert(alertWindow)
    let response = await alert.beginSheetModal(for: window)
    alertWindows.remove(alertWindow)
    if let escape { NSEvent.removeMonitor(escape) }
    token?.dismiss = nil
    let offset = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    guard (0..<buttons.count).contains(offset) else { return -1 }
    return buttons.count - 1 - offset
  }

  /// Runs an open or save panel as a sheet on the conversation window, or with `preferringKey` on
  /// the key window, or on its own when no window shows. Waits a moment for a conversation window
  /// that the File menu has just opened. Returns the chosen file or folder, or nil on Cancel.
  static func run(_ panel: NSSavePanel, preferringKey: Bool = false) async -> URL? {
    await show(panel, preferringKey: preferringKey) ? panel.url : nil
  }

  /// Runs a multi-select open panel as `run(_:preferringKey:)` does. Returns every chosen file,
  /// or none on Cancel.
  static func runMultiple(_ panel: NSOpenPanel) async -> [URL] {
    await show(panel, preferringKey: false) ? panel.urls : []
  }

  /// Shows `panel` as `run(_:preferringKey:)` describes. True when the person chose.
  private static func show(_ panel: NSSavePanel, preferringKey: Bool) async -> Bool {
    let response =
      if let window = await host(waitingUpTo: .seconds(1), preferringKey: preferringKey) {
        await panel.beginSheetModal(for: window)
      } else {
        await panel.begin()
      }
    return response == .OK
  }
}
