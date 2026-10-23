import AppKit
import MuseKit
import SwiftUI

/// The composer's text area: an NSTextView, so the keys behave as in Electron's textarea.
/// Return sends, Cmd-Return sends, Shift-Return and Option-Return add a line at the cursor, and
/// Return never interrupts input-method composition. While a popup shows, Up, Down, Tab, Return
/// and Escape go to it first. It grows from one line to `maxHeight`, then scrolls.
struct ComposerTextView: NSViewRepresentable {
  @Binding var text: String
  /// The height the text needs, from one line to `maxHeight`. The caller frames the view with it.
  @Binding var height: CGFloat
  let placeholder: String
  /// The theme's muted color: AppKit's placeholder color is too faint on the themes' fields.
  var placeholderColor = NSColor.placeholderTextColor
  var isEnabled = true
  /// Bumped when the composer should take keyboard focus, with the cursor at the end.
  var focusRequest = 0
  /// Bumped when a popup rewrote the text: the composer takes focus with the cursor at the end.
  var cursorRequest = 0
  let onSubmit: () -> Void
  /// A popup's key. Returns true when the popup took it.
  var onPopupKey: (SlashKey) -> Bool = { _ in false }
  /// Files or folders dropped on the text, for the drop plan.
  var onDropFiles: ([URL]) -> Void = { _ in }
  /// A file drag entered (true) or left (false) the text.
  var onDragChange: (Bool) -> Void = { _ in }
  /// Files or folders copied in Finder, pasted, for the drop plan.
  var onPasteFiles: ([URL]) -> Void = { _ in }
  /// Image data pasted with no text, as PNG. The composer passes it to `attachPasted` as `public.png`.
  var onPasteImage: (Data) -> Void = { _ in }

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
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.setAccessibilityIdentifier("composer")
    textView.setAccessibilityLabel("Message Muse")
    textView.string = text
    textView.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
    textView.onPopupKey = { [weak coordinator = context.coordinator] key in
      coordinator?.parent.onPopupKey(key) ?? false
    }
    textView.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.measureLater() }
    textView.onDropFiles = { [weak coordinator = context.coordinator] urls in coordinator?.parent.onDropFiles(urls) }
    textView.onDragChange = { [weak coordinator = context.coordinator] over in coordinator?.parent.onDragChange(over) }
    textView.onPasteFiles = { [weak coordinator = context.coordinator] urls in coordinator?.parent.onPasteFiles(urls) }
    textView.onPasteImage = { [weak coordinator = context.coordinator] data in coordinator?.parent.onPasteImage(data) }

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.documentView = textView
    context.coordinator.textView = textView
    // A new composer does not grab focus for a request made before it existed.
    context.coordinator.appliedFocusRequest = focusRequest
    context.coordinator.appliedCursorRequest = cursorRequest
    apply(to: textView)
    context.coordinator.measureLater()
    return scroll
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    guard let textView = scroll.documentView as? ComposerNSTextView else { return }
    textView.delegate = nil
    textView.onSubmit = nil
    textView.onPopupKey = nil
    textView.onWidthChange = nil
    textView.onDropFiles = nil
    textView.onDragChange = nil
    textView.onPasteFiles = nil
    textView.onPasteImage = nil
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = context.coordinator.textView else { return }
    // Only when the text differs, so typing never resets the cursor, and never during an
    // input-method composition, which a redraw from streamed output must not wipe. A new draft
    // (after a send, or another conversation's) keeps the selection where it still fits.
    if textView.string != text, !textView.hasMarkedText() {
      let length = (text as NSString).length
      let selection = textView.selectedRanges.map { value -> NSValue in
        let range = value.rangeValue
        let location = min(range.location, length)
        return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
      }
      textView.string = text
      textView.font = Self.font
      textView.selectedRanges = selection
      // The undo steps refer to text that is gone; Cmd-Z on them raises a range exception.
      context.coordinator.undo.removeAllActions()
      context.coordinator.measureLater()
    }
    apply(to: textView)
    // Ask Muse adds to the draft and asks for focus, so the person can keep typing.
    if context.coordinator.appliedFocusRequest != focusRequest {
      context.coordinator.appliedFocusRequest = focusRequest
      Self.focusAtEnd(textView)
    }
    // After the text above: a popup's choice puts the cursor after the text it wrote.
    if context.coordinator.appliedCursorRequest != cursorRequest {
      context.coordinator.appliedCursorRequest = cursorRequest
      Self.focusAtEnd(textView)
    }
  }

  /// Takes keyboard focus with the cursor after the last character.
  private static func focusAtEnd(_ textView: NSTextView) {
    guard let window = textView.window else { return }
    window.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    textView.scrollRangeToVisible(textView.selectedRange())
  }

  private func apply(to textView: ComposerNSTextView) {
    if textView.placeholder != placeholder {
      textView.placeholder = placeholder
      textView.setAccessibilityPlaceholderValue(placeholder)
      textView.needsDisplay = true
    }
    if textView.placeholderColor != placeholderColor {
      textView.placeholderColor = placeholderColor
      textView.needsDisplay = true
    }
    if textView.isEditable != isEnabled {
      textView.isEditable = isEnabled
      textView.textColor = isEnabled ? .labelColor : .secondaryLabelColor
    }
    // So VoiceOver reports the read-only state while a conversation opens.
    if textView.isAccessibilityEnabled() != isEnabled { textView.setAccessibilityEnabled(isEnabled) }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ComposerTextView
    weak var textView: ComposerNSTextView?
    /// The composer's own undo history, not the window's, so it can be cleared when the text
    /// is rewritten from code.
    let undo = UndoManager()
    /// The last `focusRequest` acted on.
    var appliedFocusRequest = 0
    /// The last `cursorRequest` acted on.
    var appliedCursorRequest = 0

    init(_ parent: ComposerTextView) { self.parent = parent }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

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
  var placeholderColor = NSColor.placeholderTextColor
  var onSubmit: (() -> Void)?
  var onPopupKey: ((SlashKey) -> Bool)?
  var onWidthChange: (() -> Void)?
  var onDropFiles: (([URL]) -> Void)?
  var onDragChange: ((Bool) -> Void)?
  var onPasteFiles: (([URL]) -> Void)?
  var onPasteImage: ((Data) -> Void)?
  private var focusedOnce = false

  /// The file URLs on a pasteboard: files and folders, never web links.
  private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
    pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }

  /// The pasteboard's image as PNG: PNG as it is, and TIFF (a screenshot, Preview) converted, since
  /// the backend reads an image's kind from its extension.
  private static func pngData(_ pasteboard: NSPasteboard) -> Data? {
    if let png = pasteboard.data(forType: .png) { return png }
    guard let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }

  /// File URLs too, so a file dropped on the text reaches `performDragOperation` below instead of
  /// passing by. NSTextView reads this when it registers its drag types.
  override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
    super.acceptableDragTypes + [.fileURL]
  }

  // A dropped file goes to the drop plan; NSTextView would insert its path as text. Text drags
  // behave as before.
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard isEditable, !Self.fileURLs(sender.draggingPasteboard).isEmpty else { return super.draggingEntered(sender) }
    onDragChange?(true)
    return .copy
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard isEditable, !Self.fileURLs(sender.draggingPasteboard).isEmpty else { return super.draggingUpdated(sender) }
    return .copy
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    onDragChange?(false)
    super.draggingExited(sender)
  }

  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard isEditable, !Self.fileURLs(sender.draggingPasteboard).isEmpty else {
      return super.prepareForDragOperation(sender)
    }
    return true
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let urls = Self.fileURLs(sender.draggingPasteboard)
    guard isEditable, !urls.isEmpty else { return super.performDragOperation(sender) }
    onDragChange?(false)
    onDropFiles?(urls)
    return true
  }

  /// Files copied in Finder go to the drop plan. An image with no text attaches as a PNG. Text
  /// pastes as before.
  override func paste(_ sender: Any?) {
    if !pasteAttachments() { super.paste(sender) }
  }

  /// Edit › Paste and Match Style (⌥⇧⌘V) handles files and images as Paste does.
  override func pasteAsPlainText(_ sender: Any?) {
    if !pasteAttachments() { super.pasteAsPlainText(sender) }
  }

  /// Passes the general pasteboard's files or image on. True when it took them; false leaves the
  /// paste to NSTextView.
  private func pasteAttachments() -> Bool {
    guard isEditable else { return false }
    let pasteboard = NSPasteboard.general
    if let onPasteFiles {
      let urls = Self.fileURLs(pasteboard)
      if !urls.isEmpty {
        onPasteFiles(urls)
        return true
      }
    }
    if let onPasteImage, pasteboard.string(forType: .string) == nil, let png = Self.pngData(pasteboard) {
      onPasteImage(png)
      return true
    }
    return false
  }

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

  /// The keys a popup takes: the arrows, Tab, Return and Escape, with no modifier. Shift-Return
  /// stays a new line and Shift-Tab still moves focus, as in Electron.
  private static func popupKey(_ event: NSEvent) -> SlashKey? {
    guard modifiers(event).isEmpty else { return nil }
    switch event.keyCode {
    case 125: return .down
    case 126: return .up
    case 48: return .tab
    case 36, 76: return .enter
    case 53: return .escape
    default: return nil
    }
  }

  override func keyDown(with event: NSEvent) {
    // A popup takes its keys first, while the composer is editable. Composition owns every key
    // until it commits, and a held Return repeats into the send below, which ignores repeats.
    if isEditable, !hasMarkedText(), let key = Self.popupKey(event), !(key == .enter && event.isARepeat),
      onPopupKey?(key) == true
    {
      return
    }
    // Composition owns Return: it commits the marked text.
    guard Self.isReturn(event), !hasMarkedText() else { return super.keyDown(with: event) }
    let modifiers = Self.modifiers(event)
    if modifiers.isEmpty || modifiers == .command {
      // A held Return repeats; only the first press sends.
      if !event.isARepeat, isEditable { onSubmit?() }
      return
    }
    // A plain line break: Control-Return would otherwise insert U+2028.
    if modifiers == .shift || modifiers == .option || modifiers == .control {
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

  /// Tab and Shift-Tab move focus, as in Electron's textarea, rather than typing a tab. While a
  /// popup shows, `keyDown` gives Tab to it before this runs.
  override func insertTab(_ sender: Any?) { window?.selectNextKeyView(nil) }
  override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(nil) }

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
      withAttributes: [.font: font ?? ComposerTextView.font, .foregroundColor: placeholderColor])
  }
}
