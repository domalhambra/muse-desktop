import AppKit
import SwiftUI

/// Long text in a selectable, read-only `NSTextView`: file previews and tool output. AppKit's text
/// system draws a megabyte quickly, where a SwiftUI `Text` does not. Lines do not wrap, as code,
/// unless `wraps` is on.
struct ReadOnlyTextView: NSViewRepresentable {
  let text: String
  /// The accessibility identifier, for UI tests.
  var identifier = ""
  /// What VoiceOver calls the text, such as "File preview".
  var label = ""
  var font = Self.defaultFont
  /// Wraps long lines at the view's width, as Electron's `white-space: pre-wrap` for tool output.
  /// Off, lines run on and scroll sideways, as code in the Files preview.
  var wraps = false
  /// Receives the height the text needs, up to `maxHeight`, for a box that grows with it.
  var measuredHeight: Binding<CGFloat>?
  /// The tallest box the caller draws. Measuring stops past it.
  var maxHeight = CGFloat.greatestFiniteMagnitude

  static let defaultFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
  /// The space around the text, at the top and bottom and at each side.
  static let inset = NSSize(width: 6, height: 6)

  @MainActor final class Coordinator {
    /// The text last given to the view. Comparing against it, not the view's string, is cheap when
    /// a parent re-renders with the same text.
    var text: String?
    var wraps: Bool?
    /// What the last height was measured for, so a re-render does not measure again.
    var measuredFor: MeasureKey?
    var height: CGFloat = 0
    /// Where a measured height goes, kept current by each update.
    var measuredHeight: Binding<CGFloat>?
    var maxHeight = CGFloat.greatestFiniteMagnitude

    /// Measures wrapped text at the view's current width, and reports the height.
    func measureWrapped(_ scroll: NSScrollView, font: NSFont) {
      guard let measuredHeight, let textView = scroll.documentView as? NSTextView, let text else { return }
      let width = scroll.contentView.bounds.width
      guard width > 0 else { return }
      let key = MeasureKey(text: text, font: font, maxHeight: maxHeight, scroller: 0, width: width)
      if measuredFor != key {
        measuredFor = key
        height = ReadOnlyTextView.wrappedHeight(of: textView, maxHeight: maxHeight)
      }
      report(height, to: measuredHeight)
    }

    func report(_ height: CGFloat, to binding: Binding<CGFloat>) {
      if binding.wrappedValue != height {
        Task { @MainActor in binding.wrappedValue = height }
      }
    }
  }

  struct MeasureKey: Equatable {
    let text: String
    let font: NSFont
    let maxHeight: CGFloat
    let scroller: CGFloat
    /// The width wrapped text was laid out at; 0 for text that does not wrap.
    var width: CGFloat = 0
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
    textView.textContainerInset = Self.inset
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    // A new width re-wraps the text, so wrapped text is measured again.
    let coordinator = context.coordinator
    scroll.onWidthChange = { [weak scroll] in
      guard let scroll, coordinator.wraps == true else { return }
      coordinator.measureWrapped(scroll, font: textView.font ?? Self.defaultFont)
    }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? NSTextView else { return }
    let coordinator = context.coordinator
    if textView.accessibilityIdentifier() != identifier { textView.setAccessibilityIdentifier(identifier) }
    if textView.accessibilityLabel() ?? "" != label {
      textView.setAccessibilityLabel(label.isEmpty ? nil : label)
    }
    if coordinator.wraps != wraps {
      coordinator.wraps = wraps
      Self.configure(scroll, textView: textView, wraps: wraps)
    }
    // The font first, so the new string takes it.
    if textView.font != font { textView.font = font }
    if coordinator.text != text {
      coordinator.text = text
      textView.string = text
      textView.textColor = .labelColor
    }
    coordinator.measuredHeight = measuredHeight
    coordinator.maxHeight = maxHeight
    guard let measuredHeight else { return }
    if wraps {
      coordinator.measureWrapped(scroll, font: font)
      return
    }
    // Room for a horizontal scroll bar that takes space, so the last line is not hidden under it.
    let style = scroll.scrollerStyle
    let scroller = style == .overlay ? 0 : NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
    let key = MeasureKey(text: text, font: font, maxHeight: maxHeight, scroller: scroller)
    if coordinator.measuredFor != key {
      coordinator.measuredFor = key
      coordinator.height = Self.height(
        of: text, font: font, inset: textView.textContainerInset.height, scroller: scroller, maxHeight: maxHeight)
    }
    coordinator.report(coordinator.height, to: measuredHeight)
  }

  /// Lines wrap at the view's width, or run on and scroll sideways.
  static func configure(_ scroll: NSScrollView, textView: NSTextView, wraps: Bool) {
    scroll.hasHorizontalScroller = !wraps
    textView.isHorizontallyResizable = !wraps
    textView.autoresizingMask = wraps ? [.width] : []
    textView.textContainer?.widthTracksTextView = wraps
    if wraps {
      textView.frame.size.width = scroll.contentSize.width
      textView.textContainer?.containerSize = NSSize(
        width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    } else {
      textView.textContainer?.containerSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }
  }

  /// The height wrapped text needs at the text view's width, up to `maxHeight`. It lays out
  /// TextKit 2 fragments from the top and stops past the cap, so a megabyte of output lays out
  /// only what the box can show, and the view stays on TextKit 2.
  static func wrappedHeight(of textView: NSTextView, maxHeight: CGFloat) -> CGFloat {
    let fixed = textView.textContainerInset.height * 2
    let font = textView.font ?? defaultFont
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    guard let layout = textView.textLayoutManager else { return min(lineHeight + fixed, maxHeight) }
    var bottom: CGFloat = 0
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
      fragment in
      bottom = max(bottom, fragment.layoutFragmentFrame.maxY)
      return bottom + fixed < maxHeight
    }
    return min(ceil(max(bottom, lineHeight) + fixed), maxHeight)
  }

  /// The height `text` needs, up to `maxHeight`, when lines do not wrap: the line count times the
  /// font's line height. This reads no layout manager, which would move the view off TextKit 2
  /// and lay out all of the text. A line ends at "\n", "\r\n" or a bare "\r".
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
    var afterReturn = false
    for byte in text.utf8 {
      // "\r" ends a line; a "\n" right after it belongs to the same break.
      let breaks = byte == 13 || (byte == 10 && !afterReturn)
      afterReturn = byte == 13
      guard breaks else { continue }
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
  /// Called after layout when the visible width changed.
  var onWidthChange: (() -> Void)?
  private var lastWidth: CGFloat = -1

  override func layout() {
    super.layout()
    let width = contentView.bounds.width
    if width != lastWidth {
      lastWidth = width
      onWidthChange?()
    }
  }

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
