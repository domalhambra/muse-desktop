import AppKit
import SwiftUI

@main
struct MMacApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  @State private var model = AppModel()

  var body: some Scene {
    // One window: Cmd-N must not open a second window over the same model.
    Window("mMac", id: "main") {
      ContentView(model: model)
        .frame(minWidth: 760, minHeight: 520)
        .task {
          delegate.model = model
          await model.start()
        }
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var model: AppModel?
  /// True from `.terminateLater` until its one reply.
  private var replyPending = false

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  /// Quits only after the backend has closed `muse serve`, or the person chose to keep working.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    // A second Quit while the first waits is refused; the first still gets its one reply.
    guard !replyPending else { return .terminateCancel }
    replyPending = true
    Task { @MainActor in
      let quit = await model.quit()
      replyPending = false
      sender.reply(toApplicationShouldTerminate: quit)
    }
    return .terminateLater
  }
}
