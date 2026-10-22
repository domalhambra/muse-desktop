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
  /// Receives the height the text needs, up to `maxHeight`, for a box that grows with it.
  var measuredHeight: Binding<CGFloat>?
  /// The tallest box the caller draws. Counting lines stops past it.
  var maxHeight = CGFloat.greatestFiniteMagnitude

  final class Coordinator {
    /// The text last given to the view. Comparing against it, not the view's string, is cheap when
    /// a parent re-renders with the same text.
    var text: String?
    /// What the last height was measured for, so a re-render does not count lines again.
    var measuredFor: MeasureKey?
    var height: CGFloat = 0
  }

  struct MeasureKey: Equatable {
    let text: String
    let font: NSFont
    let maxHeight: CGFloat
    let scroller: CGFloat
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    // AppKit's factory configures the text view (TextKit 2, sizing); it moves into a scroll view
    // that passes vertical scrolling on while the text fits.
    let factory = NSTextView.scrollableTextView()
    let scroll = NestedScrollView()
    scroll.hasVerticalScroller = true
    if let textView = factory.documentView {
      factory.documentView = nil
      scroll.documentView = textView
    }
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
    // The scroll view's find bar is ready for when the app gains a Find menu item. mMac has none
    // yet, so Command-F does nothing here.
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
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
    if textView.accessibilityLabel() ?? "" != label {
      textView.setAccessibilityLabel(label.isEmpty ? nil : label)
    }
    // The font first, so the new string takes it.
    if textView.font != font { textView.font = font }
    if context.coordinator.text != text {
      context.coordinator.text = text
      textView.string = text
      textView.textColor = .labelColor
    }
    guard let measuredHeight else { return }
    // Room for a horizontal scroll bar that takes space, so the last line is not hidden under it.
    let style = scroll.scrollerStyle
    let scroller = style == .overlay ? 0 : NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
    let key = MeasureKey(text: text, font: font, maxHeight: maxHeight, scroller: scroller)
    if context.coordinator.measuredFor != key {
      context.coordinator.measuredFor = key
      context.coordinator.height = Self.height(
        of: text, font: font, inset: textView.textContainerInset.height, scroller: scroller, maxHeight: maxHeight)
    }
    let height = context.coordinator.height
    if measuredHeight.wrappedValue != height {
      Task { @MainActor in measuredHeight.wrappedValue = height }
    }
  }

  /// The height `text` needs, up to `maxHeight`. Lines do not wrap, so it is the line count times
  /// the font's line height. This reads no layout manager, which would move the view off TextKit 2
  /// and lay out all of the text.
  static func height(of text: String, font: NSFont, inset: CGFloat, scroller: CGFloat, maxHeight: CGFloat)
    -> CGFloat
  {
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    let fixed = inset * 2 + scroller
    // Enough lines to pass the cap; counting further changes nothing.
    let cap =
      maxHeight < .greatestFiniteMagnitude
      ? max(Int(((maxHeight - fixed) / lineHeight).rounded(.up)), 0) + 1 : Int.max
    var lines = 1
    for byte in text.utf8 where byte == 10 {
      lines += 1
      if lines >= cap { break }
    }
    return min(ceil(CGFloat(lines) * lineHeight + fixed), maxHeight)
  }
}

/// A scroll view that sits inside another one, such as a tool output box in the transcript. While
/// its text fits vertically, it hands vertical scrolling to the enclosing view, so a wheel or
/// trackpad over a short box scrolls the transcript instead of stopping at the box. Horizontal
/// scrolling, and vertical scrolling once the text is taller than the box, stay with it.
final class NestedScrollView: NSScrollView {
  override func scrollWheel(with event: NSEvent) {
    let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    if !horizontal, !canScrollVertically, let next = nextResponder {
      next.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }

  var canScrollVertically: Bool {
    guard let document = documentView else { return false }
    return document.frame.height > contentView.bounds.height + 1
  }
}
