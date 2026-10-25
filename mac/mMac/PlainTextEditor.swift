import AppKit
import SwiftUI

/// Text fields that keep text exactly as typed, for commands, arguments, URLs and env values.
/// AppKit's text views follow the system's text settings: a new `NSTextView` turns `--port "x"`
/// into `—port “x”`, and a window's field editor keeps text replacement and spelling correction
/// on. SwiftUI's `TextEditor` and `TextField` cannot turn all of them off. Electron's inputs
/// never change what is typed.
@MainActor
enum PlainText {
  /// Turns off every substitution, correction and check on `textView`.
  static func configure(_ textView: NSTextView) {
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextCompletionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.enabledTextCheckingTypes = 0
    // macOS 14 and 15 add inline predictions, math results after "=" and Writing Tools.
    textView.inlinePredictionType = .no
    textView.mathExpressionCompletionType = .no
    textView.writingToolsBehavior = .none
  }
}

/// A scrolling multi-line plain-text field, in place of `TextEditor`. Tab moves to the next
/// field, as in Electron's textarea; Return makes a new line.
struct PlainTextEditor: NSViewRepresentable {
  @Binding var text: String
  /// What VoiceOver reads for the field.
  let accessibilityLabel: String
  /// Told when the field gains or loses keyboard focus, so a sheet can drop its default button
  /// while Return belongs to the field.
  var onFocusChange: @MainActor (Bool) -> Void = { _ in }
  @Environment(\.appearance) private var appearance

  static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  /// One line of `font`.
  static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
  /// The space between the text and the field's edge.
  static let inset = NSSize(width: 3, height: 4)

  /// The field's height for `lines` lines of text.
  static func height(lines: Int) -> CGFloat { CGFloat(lines) * lineHeight + inset.height * 2 }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = FocusReportingTextView(frame: .zero)
    PlainText.configure(textView)
    textView.allowsUndo = true
    textView.font = Self.font
    textView.textContainerInset = Self.inset
    // The field's own background is drawn by SwiftUI, with its rounded border.
    textView.drawsBackground = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.string = text
    textView.delegate = context.coordinator

    let scrollView = FillingScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    update(textView, coordinator: context.coordinator)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scrollView.documentView as? FocusReportingTextView else { return }
    if textView.string != text { textView.string = text }
    update(textView, coordinator: context.coordinator)
  }

  private func update(_ textView: FocusReportingTextView, coordinator: Coordinator) {
    let color = NSColor(appearance.colors.text)
    textView.textColor = color
    textView.insertionPointColor = color
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.onFocusChange = { [weak coordinator] focused in
      // Told after AppKit's responder change, never inside a SwiftUI update.
      Task { @MainActor in coordinator?.parent.onFocusChange(focused) }
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PlainTextEditor

    init(_ parent: PlainTextEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertTab(_:)):
        textView.window?.selectNextKeyView(nil)
        return true
      case #selector(NSResponder.insertBacktab(_:)):
        textView.window?.selectPreviousKeyView(nil)
        return true
      default:
        return false
      }
    }
  }
}

/// A scroll view whose text view is never shorter than the visible box. An empty text view is
/// one line tall, so a click below that line landed on the clip view and focused nothing: the
/// M4b live run's "clicking Arguments or Environment does not move focus".
final class FillingScrollView: NSScrollView {
  override func tile() {
    super.tile()
    guard let textView = documentView as? NSTextView else { return }
    let height = contentSize.height
    guard textView.minSize.height != height else { return }
    textView.minSize = NSSize(width: 0, height: height)
    if textView.frame.height < height { textView.setFrameSize(NSSize(width: textView.frame.width, height: height)) }
  }
}

/// An `NSTextView` that reports when it gains or loses keyboard focus.
final class FocusReportingTextView: NSTextView {
  var onFocusChange: ((Bool) -> Void)?

  /// A click in a window that is not key focuses the field it lands on, as it does in Electron,
  /// instead of only bringing the sheet forward and leaving focus where it was.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    super.mouseDown(with: event)
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocusChange?(true) }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocusChange?(false) }
    return resigned
  }

  /// A field the sheet removes, such as Arguments when the form turns to Remote URL, gives up
  /// focus without `resignFirstResponder`.
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil, window?.firstResponder === self { onFocusChange?(false) }
    super.viewWillMove(toWindow: newWindow)
  }

  /// Escape shows no completion list. Text completion is off, but `complete(_:)` still lists words.
  override func complete(_ sender: Any?) {}
}

/// A single-line plain-text field, in place of `TextField`. The window's field editor is set up
/// as the field takes focus, since its text replacement and spelling correction are on.
struct PlainTextField: NSViewRepresentable {
  /// What VoiceOver reads for the field.
  let accessibilityLabel: String
  @Binding var text: String
  var placeholder = ""
  /// The accessibility identifier, for UI tests.
  var identifier = ""
  /// Told when editing ends: on Return, and when the field loses focus. `shown` is false when
  /// editing ended because the field left its window or the window closed.
  var onEndEditing: (@MainActor (_ shown: Bool) -> Void)?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSTextField {
    let field = PlainFieldView()
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.isEditable = true
    field.isSelectable = true
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.isAutomaticTextCompletionEnabled = false
    // Fill the width SwiftUI gives, and never widen to fit a long command.
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.stringValue = text
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    field.placeholderString = placeholder
    field.setAccessibilityLabel(accessibilityLabel)
    if !identifier.isEmpty { field.setAccessibilityIdentifier(identifier) }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: PlainTextField

    init(_ parent: PlainTextField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      guard let onEndEditing = parent.onEndEditing else { return }
      let field = notification.object as? NSTextField
      // Told after AppKit's responder change, never inside a SwiftUI update. By then a field
      // whose pane went away is out of its window, and a closed window is no longer visible.
      Task { @MainActor [weak field] in onEndEditing(field?.window?.isVisible == true) }
    }
  }
}

/// An `NSTextField` that turns off its field editor's substitutions each time it takes focus.
/// The field editor is the window's, shared by its fields, so it is set up again every time.
final class PlainFieldView: NSTextField {
  /// A click in a window that is not key focuses this field, as it does in Electron. Without it
  /// the click only brings the sheet forward, and typing goes to the field that had focus: the
  /// M4b live run's "clicking Command does not move focus; all text goes into Name".
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// The click makes this field the first responder before AppKit tracks it, so focus moves even
  /// when another field's editor holds it.
  override func mouseDown(with event: NSEvent) {
    if let window, currentEditor() == nil { window.makeFirstResponder(self) }
    super.mouseDown(with: event)
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became, let editor = currentEditor() as? NSTextView { PlainText.configure(editor) }
    return became
  }
}
