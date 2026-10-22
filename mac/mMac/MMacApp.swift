import AppKit
import SwiftUI

@main
struct MMacApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  static let mainWindow = "main"

  /// Where `@AppStorage` keeps the window's choices, such as `inspectorShown`. Debug builds take
  /// `MMAC_DEFAULTS_SUITE` from the UI tests: a suite of their own, emptied at launch, so a test
  /// starts from the defaults and never reads or changes Dom's. The test runner is sandboxed and
  /// cannot reach mMac's preferences itself.
  static let appStorage: UserDefaults = {
    #if DEBUG
      if let suite = ProcessInfo.processInfo.environment["MMAC_DEFAULTS_SUITE"], !suite.isEmpty,
        let defaults = UserDefaults(suiteName: suite)
      {
        defaults.removePersistentDomain(forName: suite)
        return defaults
      }
    #endif
    return .standard
  }()

  var body: some Scene {
    // One window. The backend belongs to the app, so closing this window keeps it.
    Window("mMac", id: Self.mainWindow) {
      RootView(controller: delegate.controller)
        .frame(minWidth: 820, minHeight: 560)
        // Muse and Moonlight, the two kept themes, are both dark. Themes arrive in M3.
        .preferredColorScheme(.dark)
        .defaultAppStorage(Self.appStorage)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        FileCommands(controller: delegate.controller)
      }
      CommandGroup(after: .sidebar) {
        InspectorCommand()
      }
    }
    // mMac › Settings… (Command-comma). Its panes show only while a backend runs.
    Settings {
      SettingsView(controller: delegate.controller)
        .defaultAppStorage(Self.appStorage)
        .preferredColorScheme(.dark)
    }
  }
}

/// The File menu's items. A view, so its `disabled` states follow the controller as it changes.
private struct FileCommands: View {
  let controller: AppController

  var body: some View {
    // Both open the window first when it is closed, so the result has somewhere to show.
    Button("New conversation") {
      controller.revealWindow()
      controller.workspace?.startNew()
    }
    .keyboardShortcut("n")
    .disabled(controller.workspace == nil)
    Button("Open project…") {
      controller.revealWindow()
      Task { await controller.openProject() }
    }
    .keyboardShortcut("o")
    .disabled(controller.workspace == nil)
  }
}

/// View → Show Inspector. It shares the stored choice with the toolbar button.
private struct InspectorCommand: View {
  // The store is named here: a menu item does not reliably read the window's `defaultAppStorage`.
  @AppStorage("inspectorShown", store: MMacApp.appStorage) private var inspectorShown = false

  var body: some View {
    Button(inspectorShown ? "Hide Inspector" : "Show Inspector") { inspectorShown.toggle() }
      .keyboardShortcut("i", modifiers: [.command, .option])
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let controller = AppController()
  /// True from `.terminateLater` until its one reply.
  private var replyPending = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await controller.start() }
  }

  /// Closing the window keeps mMac and its backend running, so a turn is never cut off unasked.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// A Dock click with no window open reopens it.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if flag { return true }
    return !controller.revealWindow()
  }

  /// Quits after the backend has closed `muse serve`, or when the person chose to keep working.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if replyPending {
      // A second Quit while the backend has not answered: stop it now. The first Quit then replies.
      controller.forceQuit()
      return .terminateCancel
    }
    replyPending = true
    Task {
      let quit = await controller.quit()
      replyPending = false
      sender.reply(toApplicationShouldTerminate: quit)
    }
    return .terminateLater
  }
}
