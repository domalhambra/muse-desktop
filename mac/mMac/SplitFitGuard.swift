import AppKit
import MuseKit
import SwiftUI

/// Grows the window it is in when the window's split view is wider than the window's content.
/// The `NavigationSplitView` opens the inspector at its ideal width and does not shrink the
/// sidebar to make room, so at the default 900 points the split view ran past both window edges
/// (`WindowFit` in MuseKit). The guard watches the outermost split view's frame and gives the
/// window the width it takes, as far as the screen allows. A full-screen window is left alone.
struct SplitFitGuard: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { GuardView() }
  func updateNSView(_ view: NSView, context: Context) {}

  final class GuardView: NSView {
    private weak var split: NSSplitView?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      split = nil
      guard window != nil else { return }
      // SwiftUI sets up the split views around this view after it is in the window.
      DispatchQueue.main.async { [weak self] in self?.watch() }
    }

    private func watch() {
      guard let window, let content = window.contentView, let split = Self.outermostSplitView(in: content)
      else { return }
      self.split = split
      split.postsFrameChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(splitFrameChanged), name: NSView.frameDidChangeNotification, object: split)
      fit()
    }

    @objc private func splitFrameChanged(_ notification: Notification) {
      // Not inside the split view's layout pass: the window's resize lays it out again.
      DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    private func fit() {
      guard let window, let content = window.contentView, let split, let screen = window.screen,
        !window.styleMask.contains(.fullScreen)
      else { return }
      if let frame = WindowFit.grown(
        window: window.frame, contentWidth: content.bounds.width, splitWidth: split.frame.width,
        screen: screen.visibleFrame)
      {
        window.setFrame(frame, display: true)
      }
    }

    /// The first split view under `view`, breadth first: the sidebar's, which holds the others.
    static func outermostSplitView(in view: NSView) -> NSSplitView? {
      var queue = [view]
      while !queue.isEmpty {
        let next = queue.removeFirst()
        if let split = next as? NSSplitView { return split }
        queue.append(contentsOf: next.subviews)
      }
      return nil
    }
  }
}
