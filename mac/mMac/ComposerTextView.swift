import AppKit
import SwiftUI

/// The composer's text area: an NSTextView, so the keys behave as in Electron's textarea.
/// Return sends, Cmd-Return sends, Shift-Return and Option-Return add a line at the cursor, and
/// Return never interrupts input-method composition. It grows from one line to `maxHeight`, then
/// scrolls.
struct ComposerTextView: NSViewRepresentable {
  @Binding var text: String
  /// The height the text needs, from one line to `maxHeight`. The caller frames the view with it.
  @Binding var height: CGFloat
  let placeholder: String
  var isEnabled = true
  let onSubmit: () -> Void

  static let maxHeight: CGFloat = 200
  static let font = NSFont.preferredFont(forTextStyle: .body)

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layout.addTextContainer(container)

    let textView = ComposerNSTextView(frame: .zero, textContainer: container)
    textView.delegate = context.coordinator
    textView.font = Self.font
    textView.textColor = .labelColor
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    // Code and commands are typed here: no smart quotes, dashes or text replacement.
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.setAccessibilityIdentifier("composer")
    textView.setAccessibilityLabel("Message Muse")
    textView.string = text
    textView.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
    textView.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.measureLater() }

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.documentView = textView
    context.coordinator.textView = textView
    apply(to: textView)
    context.coordinator.measureLater()
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = context.coordinator.textView else { return }
    // Only when the text differs, so typing never resets the cursor. A new draft (after a send,
    // or another conversation's) keeps the selection where it still fits.
    if textView.string != text {
      let length = (text as NSString).length
      let selection = textView.selectedRanges.map { value -> NSValue in
        let range = value.rangeValue
        let location = min(range.location, length)
        return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
      }
      textView.string = text
      textView.font = Self.font
      textView.selectedRanges = selection
      context.coordinator.measureLater()
    }
    apply(to: textView)
  }

  private func apply(to textView: ComposerNSTextView) {
    if textView.placeholder != placeholder {
      textView.placeholder = placeholder
      textView.setAccessibilityPlaceholderValue(placeholder)
      textView.needsDisplay = true
    }
    if textView.isEditable != isEnabled {
      textView.isEditable = isEnabled
      textView.textColor = isEnabled ? .labelColor : .secondaryLabelColor
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ComposerTextView
    weak var textView: ComposerNSTextView?

    init(_ parent: ComposerTextView) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView else { return }
      if parent.text != textView.string { parent.text = textView.string }
      measure()
    }

    /// After the current layout pass: a size change must not land during a SwiftUI update.
    func measureLater() {
      DispatchQueue.main.async { [weak self] in self?.measure() }
    }

    private func measure() {
      guard let textView else { return }
      let needed = min(max(textView.fittingHeight(), textView.lineHeight), ComposerTextView.maxHeight)
      if abs(parent.height - needed) > 0.5 { parent.height = needed }
    }
  }
}

/// The NSTextView behind the composer: its keys, its placeholder, its first focus.
final class ComposerNSTextView: NSTextView {
  var placeholder = ""
  var onSubmit: (() -> Void)?
  var onWidthChange: (() -> Void)?
  private var focusedOnce = false

  var lineHeight: CGFloat {
    let font = font ?? ComposerTextView.font
    return ceil(layoutManager?.defaultLineHeight(for: font) ?? font.pointSize * 1.25)
  }

  /// The height of the laid-out text, including the empty line after a trailing newline.
  func fittingHeight() -> CGFloat {
    guard let layoutManager, let textContainer else { return lineHeight }
    layoutManager.ensureLayout(for: textContainer)
    return ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2)
  }

  private static func isReturn(_ event: NSEvent) -> Bool {
    // Return, and Enter on the keypad.
    event.keyCode == 36 || event.keyCode == 76
  }

  private static func modifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
    event.modifierFlags.intersection([.shift, .option, .command, .control])
  }

  override func keyDown(with event: NSEvent) {
    // Composition owns Return: it commits the marked text.
    guard Self.isReturn(event), !hasMarkedText() else { return super.keyDown(with: event) }
    let modifiers = Self.modifiers(event)
    if modifiers.isEmpty || modifiers == .command {
      // A held Return repeats; only the first press sends.
      if !event.isARepeat, isEditable { onSubmit?() }
      return
    }
    if modifiers == .shift || modifiers == .option {
      if isEditable { insertNewlineIgnoringFieldEditor(nil) }
      return
    }
    super.keyDown(with: event)
  }

  /// Cmd-Return reaches key equivalents before keyDown. Send it here, from the focused composer only.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder === self, event.type == .keyDown, Self.isReturn(event),
      Self.modifiers(event) == .command, !hasMarkedText()
    {
      if !event.isARepeat, isEditable { onSubmit?() }
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func didChangeText() {
    super.didChangeText()
    // The placeholder shows only while the text is empty.
    needsDisplay = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(newSize.width - frame.width) > 0.5
    super.setFrameSize(newSize)
    if widthChanged { onWidthChange?() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Takes focus once, when the composer first appears.
    guard let window, !focusedOnce else { return }
    focusedOnce = true
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window else { return }
      window.makeFirstResponder(self)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let padding = textContainer?.lineFragmentPadding ?? 0
    let origin = textContainerOrigin
    (placeholder as NSString).draw(
      at: NSPoint(x: origin.x + padding, y: origin.y),
      withAttributes: [.font: font ?? ComposerTextView.font, .foregroundColor: NSColor.placeholderTextColor])
  }
}
