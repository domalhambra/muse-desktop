import AppKit
import SwiftUI

/// Long text in a selectable, read-only `NSTextView`: file previews and tool output. AppKit's text
/// system draws a megabyte quickly, where a SwiftUI `Text` does not. Lines do not wrap, as code.
struct ReadOnlyTextView: NSViewRepresentable {
  let text: String
  /// The accessibility identifier, for UI tests.
  var identifier = ""
  /// What VoiceOver calls the text, such as "File preview".
  var label = ""
  var font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
  /// Receives the height the text needs, for a box that grows with it up to a limit.
  var measuredHeight: Binding<CGFloat>?

  final class Coordinator {
    /// The text last given to the view. Comparing against it, not the view's string, is cheap when
    /// a parent re-renders with the same text.
    var text: String?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    guard let textView = scroll.documentView as? NSTextView else { return scroll }
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = font
    textView.textColor = .labelColor
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.isHorizontallyResizable = true
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? NSTextView else { return }
    if textView.accessibilityIdentifier() != identifier { textView.setAccessibilityIdentifier(identifier) }
    if textView.accessibilityLabel() ?? "" != label { textView.setAccessibilityLabel(label.isEmpty ? nil : label) }
    if context.coordinator.text != text {
      context.coordinator.text = text
      textView.string = text
      textView.font = font
      textView.textColor = .labelColor
    } else if textView.font != font {
      textView.font = font
    }
    guard let measuredHeight, let layout = textView.layoutManager, let container = textView.textContainer
    else { return }
    layout.ensureLayout(for: container)
    // Room for a horizontal scroll bar, so the last line is not hidden under it.
    let height = ceil(layout.usedRect(for: container).height + textView.textContainerInset.height * 2 + 14)
    if measuredHeight.wrappedValue != height {
      Task { @MainActor in measuredHeight.wrappedValue = height }
    }
  }
}
