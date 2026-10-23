import AppKit
import SwiftUI

/// Turns off AppKit's frame autosave for the window it is in, and for the window's split views,
/// when `MMacApp.keepsWindowState` is false. SwiftUI names the autosaves when it builds a window
/// (the conversation window and the Settings window) and the `NavigationSplitView`, so the guard
/// clears them once it is in the window, and again on the next turn of the run loop, after
/// SwiftUI has set up the views around it.
struct WindowStateGuard: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { GuardView() }
  func updateNSView(_ view: NSView, context: Context) {}

  final class GuardView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard !MMacApp.keepsWindowState, let window else { return }
      WindowStateGuard.stopAutosaving(in: window)
      DispatchQueue.main.async { [weak window] in
        if let window { WindowStateGuard.stopAutosaving(in: window) }
      }
    }
  }

  /// Clears the frame autosave name of `window` and of every split view in it.
  static func stopAutosaving(in window: NSWindow) {
    if !window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("") }
    var views = [window.contentView].compactMap { $0 }
    while let view = views.popLast() {
      if let split = view as? NSSplitView, split.autosaveName != nil { split.autosaveName = nil }
      views.append(contentsOf: view.subviews)
    }
  }
}
