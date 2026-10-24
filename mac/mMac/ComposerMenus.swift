import AppKit
import MuseBackend
import MuseKit
import SwiftUI
import os

/// A list that floats above the composer. The composer keeps keyboard focus: its keys move the
/// highlight, and a click chooses a row.
struct ComposerPopup<Row: View>: View {
  /// What VoiceOver reads for the list, as Electron's `aria-label`.
  let label: String
  let identifier: String
  let count: Int
  let selected: Int
  /// Each row's accessibility identifier, as Electron's option ids.
  let rowIdentifier: (Int) -> String
  let choose: (Int) -> Void
  @ViewBuilder let row: (Int) -> Row
  @Environment(\.appearance) private var appearance

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(0..<count, id: \.self) { index in
            row(index)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(index == selected ? appearance.colors.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
              .contentShape(.rect)
              .onTapGesture { choose(index) }
              .accessibilityElement(children: .combine)
              .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
              .accessibilityAction { choose(index) }
              .accessibilityIdentifier(rowIdentifier(index))
              .id(index)
          }
        }
        .padding(5)
      }
      .scrollIndicators(.visible)
      // As tall as the rows, up to 306 points: Electron's 290 fit exactly ten rows, so an
      // eleventh (/btw) sat under the edge with nothing to say the list scrolls. 306 shows about
      // half of the eleventh row, and the scroller shows while the list can scroll.
      .frame(maxHeight: 306)
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: selected) { proxy.scrollTo(selected) }
    }
    .background(appearance.colors.dialog, in: RoundedRectangle(cornerRadius: 15))
    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.12)))
    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }
}

/// The slash-command popup, as Electron's `.slash-menu`.
struct SlashCommandMenu: View {
  let commands: [ComposerCommand]
  let selected: Int
  let choose: (Int) -> Void

  var body: some View {
    ComposerPopup(
      label: "Composer commands", identifier: "composer-commands", count: commands.count, selected: selected,
      rowIdentifier: { "command-\(commands[$0].name)" }, choose: choose
    ) { index in
      HStack(spacing: 8) {
        Text("/\(commands[index].name)").bold()
        Text(commands[index].description).foregroundStyle(.themeSecondary).lineLimit(1)
      }
    }
  }
}

/// The @ popup, as Electron's `.mention-menu`. Its rows come from Task 7's `MentionMenu`.
struct MentionList: View {
  let files: [ProjectFile]
  let selected: Int
  let choose: (Int) -> Void

  var body: some View {
    ComposerPopup(
      label: "Project files", identifier: "composer-mentions", count: files.count, selected: selected,
      rowIdentifier: { "mention-\(files[$0].path)" }, choose: choose
    ) { index in
      HStack(spacing: 8) {
        Image(systemName: files[index].directory ? "folder" : "doc.text")
          .foregroundStyle(.themeSecondary)
          .accessibilityHidden(true)
        Text(files[index].path).bold().lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
        Text(files[index].directory ? "Folder" : "File").font(.caption).foregroundStyle(.themeSecondary)
      }
    }
  }
}

/// Opens one of the composer's pickers, as Electron's `muse:select` event opens its Select.
/// SwiftUI cannot open a menu-style Picker, so this finds its pop-up button by accessibility
/// identifier. A disabled picker stays shut, as Electron's does.
@MainActor
enum PickerOpener {
  private static let log = Logger(subsystem: "com.domalhambra.mmac", category: "composer")

  static func open(_ identifier: String) {
    guard let window = NSApp.windows.first(where: { $0.isVisible && MMacApp.isMainWindow($0) }),
      let content = window.contentView
    else { return }
    guard let button = find(identifier, in: content) else {
      // SwiftUI may stop putting the identifier on the pop-up button; say so rather than do nothing.
      log.error("No pop-up button with identifier \(identifier, privacy: .public)")
      return
    }
    guard button.isEnabled else { return }
    window.makeFirstResponder(button)
    // After this turn of the run loop: the menu tracks in a loop of its own, which must not start
    // inside a SwiftUI update.
    DispatchQueue.main.async { [weak button] in button?.performClick(nil) }
  }

  private static func find(_ identifier: String, in view: NSView) -> NSPopUpButton? {
    if let button = view as? NSPopUpButton, button.accessibilityIdentifier() == identifier { return button }
    for subview in view.subviews {
      if let found = find(identifier, in: subview) { return found }
    }
    return nil
  }
}
