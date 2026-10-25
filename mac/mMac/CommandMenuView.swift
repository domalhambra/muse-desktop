import AppKit
import MuseBackend
import MuseKit
import SwiftUI
import os

/// The ⌘K sheet, as Electron's `CommandMenu.tsx`: the three actions, recent conversations and the
/// themes, filtered as the person types. `CommandMenu` in MuseKit builds and filters the entries.
struct CommandMenuView: View {
  private static let log = Logger(subsystem: "com.domalhambra.mmac", category: "command-menu")
  let controller: AppController
  let workspace: Workspace
  @Environment(\.appearance) private var appearance
  @State private var query = ""
  /// The highlighted row. Up and Down stop at the ends; typing goes back to the first row.
  @State private var selected = 0

  var body: some View {
    // Built once per render, for the list, the keys and the empty state.
    let entries = CommandMenu.entries(
      sessions: workspace.sessions, archived: workspace.preferences.archivedSessionIds, query: query)
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.themeSecondary).accessibilityHidden(true)
        CommandSearchField(text: $query) { key in handle(key, entries: entries) }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      Divider()
      results(entries)
      Divider()
      footer
    }
    .frame(width: 580)
    .background(appearance.colors.dialog)
    .onChange(of: query) { _, query in
      selected = 0
      let count = CommandMenu.entries(
        sessions: workspace.sessions, archived: workspace.preferences.archivedSessionIds, query: query
      ).count
      Self.log.debug("⌘K query \"\(query, privacy: .public)\": \(count) entries")
    }
    // A backend event can shrink the list while the sheet shows; keep the highlight on a row, so
    // Return opens the row that looks highlighted.
    .onChange(of: entries.count) { _, count in selected = min(selected, max(count - 1, 0)) }
    .onExitCommand(perform: close)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Search")
    .accessibilityIdentifier("command-menu")
  }

  @ViewBuilder private func results(_ entries: [CommandMenuEntry]) -> some View {
    if entries.isEmpty {
      Text(CommandMenu.emptyState)
        .foregroundStyle(.themeSecondary)
        .frame(maxWidth: .infinity, minHeight: 80)
        .accessibilityIdentifier("command-empty")
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
              // A heading wherever the group changes, as Electron draws them.
              if index == 0 || entries[index - 1].group != entry.group {
                Text(entry.group.rawValue.uppercased())
                  .font(.system(size: 11, weight: .semibold))
                  .tracking(0.66)
                  .foregroundStyle(.themeSecondary)
                  .padding(.horizontal, 20)
                  .padding(.top, 10)
                  .padding(.bottom, 4)
                  .accessibilityAddTraits(.isHeader)
              }
              // The row's scroll id is the entry's, as the ForEach's: an index id would let the
              // lazy stack keep the old row at that index when the filter changes.
              row(entry, index: index, entries: entries).id(entry.id)
            }
          }
          .padding(.vertical, 6)
        }
        // As tall as the rows, up to Electron's 360 points.
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: selected) {
          if entries.indices.contains(selected) { proxy.scrollTo(entries[selected].id) }
        }
      }
    }
  }

  private func row(_ entry: CommandMenuEntry, index: Int, entries: [CommandMenuEntry]) -> some View {
    HStack(spacing: 10) {
      Image(systemName: Self.symbol(entry.action))
        .frame(width: 18)
        .foregroundStyle(.themeSecondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.title).lineLimit(1)
        Text(entry.subtitle).font(.caption).foregroundStyle(.themeSecondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      if let shortcut = entry.shortcut {
        KeyCap(text: shortcut)
      } else {
        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.themeSecondary).accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(index == selected ? appearance.colors.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    .padding(.horizontal, 6)
    .contentShape(.rect)
    .onHover { if $0 { selected = index } }
    .onTapGesture { choose(index, in: entries) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { choose(index, in: entries) }
    .accessibilityIdentifier("palette-\(entry.id)")
  }

  /// Electron's key hints.
  private var footer: some View {
    HStack(spacing: 16) {
      hint(["↑", "↓"], "Navigate")
      hint(["↵"], "Open")
      hint(["esc"], "Close")
      Spacer()
    }
    .font(.caption)
    .foregroundStyle(.themeSecondary)
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
  }

  private func hint(_ keys: [String], _ label: String) -> some View {
    HStack(spacing: 4) {
      ForEach(keys, id: \.self) { KeyCap(text: $0) }
      Text(label)
    }
    .accessibilityElement(children: .combine)
  }

  private func handle(_ key: CommandSearchField.Key, entries: [CommandMenuEntry]) {
    if key == .escape { return close() }
    // `moved` returns 0 for an empty list, so with no entries Up, Down and Return do nothing.
    guard !entries.isEmpty else { return }
    switch key {
    case .down: selected = CommandMenu.moved(selected, by: 1, count: entries.count)
    case .up: selected = CommandMenu.moved(selected, by: -1, count: entries.count)
    case .enter: choose(selected, in: entries)
    case .escape: close()
    }
  }

  /// Closes the sheet; the window then runs the result, as Electron's `invoke` closes first.
  private func choose(_ index: Int, in entries: [CommandMenuEntry]) {
    // A list that shrank while the sheet showed can leave the highlight past its end.
    guard entries.indices.contains(index) else { return }
    controller.sheets.chosen = entries[index].action
    close()
  }

  private func close() { controller.sheets.commandMenu = false }

  /// Electron's row icons, as SF Symbols.
  static func symbol(_ action: CommandMenuAction) -> String {
    switch action {
    case .newConversation: "plus"
    case .openProject: "folder"
    case .openSettings: "gearshape"
    case .open: "bubble.left"
    case .theme(let theme): ThemeName(preference: theme) == .muse ? "paintpalette" : "moon"
    }
  }
}

/// A key, as Electron's `kbd`.
struct KeyCap: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption.monospaced())
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
  }
}

/// The ⌘K field. An AppKit field, so Up, Down, Return and Escape reach the list before the field
/// editor moves the cursor, and so it takes focus as the sheet opens. Text stays as typed.
struct CommandSearchField: NSViewRepresentable {
  enum Key { case up, down, enter, escape }

  @Binding var text: String
  let onKey: (Key) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSTextField {
    let field = CommandFieldView()
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.isEditable = true
    field.isSelectable = true
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.font = .systemFont(ofSize: 15)
    field.isAutomaticTextCompletionEnabled = false
    field.placeholderString = CommandMenu.placeholder
    field.setAccessibilityLabel(CommandMenu.fieldLabel)
    field.setAccessibilityIdentifier("command-search")
    field.stringValue = text
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: CommandSearchField

    init(_ parent: CommandSearchField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      // Composition owns these keys until it commits.
      if textView.hasMarkedText() { return false }
      switch selector {
      case #selector(NSResponder.moveUp(_:)): parent.onKey(.up)
      case #selector(NSResponder.moveDown(_:)): parent.onKey(.down)
      case #selector(NSResponder.insertNewline(_:)): parent.onKey(.enter)
      case #selector(NSResponder.cancelOperation(_:)): parent.onKey(.escape)
      default: return false
      }
      return true
    }
  }
}

/// The ⌘K field's view: it takes focus once it joins the sheet's window, and turns off the field
/// editor's substitutions, as `PlainFieldView` does.
final class CommandFieldView: NSTextField {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window else { return }
      window.makeFirstResponder(self)
    }
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became, let editor = currentEditor() as? NSTextView { PlainText.configure(editor) }
    return became
  }
}
