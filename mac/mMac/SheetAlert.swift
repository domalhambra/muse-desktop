import AppKit

/// Lets a caller close an alert that is still showing.
@MainActor
final class AlertToken {
  fileprivate var dismiss: (() -> Void)?
  /// Closes the alert, which then answers -1.
  func close() { dismiss?() }
}

/// Alerts and open panels as sheets on mMac's window. An alert goes on top of any sheet already
/// open there, such as Rename, so an Ask that the rename starts still shows.
@MainActor
enum SheetAlert {
  /// The window a new sheet attaches to: the front-most sheet of the main window. With no window
  /// showing, waits up to `limit` for one, since an Ask reopens the window first.
  static func host(waitingUpTo limit: Duration = .zero) async -> NSWindow? {
    let deadline = ContinuousClock.now + limit
    while true {
      if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
        var front = window
        // A sheet is itself a window, and can carry a sheet of its own.
        while let sheet = front.attachedSheet { front = sheet }
        return front
      }
      if ContinuousClock.now >= deadline { return nil }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  /// Shows an alert and returns the chosen button's index, or -1 when it was closed through
  /// `token` or no window showed. The last button is the default and the cancel choice, as in
  /// every Electron dialog the Asks replace: Return and Escape both choose it.
  static func present(
    title: String, message: String, detail: String? = nil, buttons: [String], token: AlertToken? = nil
  ) async -> Int {
    guard !buttons.isEmpty, let window = await host(waitingUpTo: .seconds(1)) else { return -1 }
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
      // Local monitors run on the main thread. An NSEvent is not Sendable, so only its window
      // goes in, and only a Bool comes out.
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
    let response = await alert.beginSheetModal(for: window)
    if let escape { NSEvent.removeMonitor(escape) }
    token?.dismiss = nil
    let offset = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    guard (0..<buttons.count).contains(offset) else { return -1 }
    return buttons.count - 1 - offset
  }

  /// Runs an open panel as a sheet on the window, or on its own when no window shows.
  static func run(_ panel: NSOpenPanel) async -> URL? {
    let response =
      if let window = await host() {
        await panel.beginSheetModal(for: window)
      } else {
        await panel.begin()
      }
    return response == .OK ? panel.url : nil
  }
}
