import MuseKit
import SwiftUI

/// What /help opens. mMac has no docs page, so this sheet lists the composer's commands and the
/// window's shortcuts, and points at the full CLI.
struct HelpSheet: View {
  let close: () -> Void

  struct Shortcut: Identifiable {
    let keys: String
    let action: String
    var id: String { keys }
  }

  /// The shortcuts, in the spec's order.
  static let shortcuts = [
    Shortcut(keys: "⌘K", action: "Search commands and conversations"),
    Shortcut(keys: "⌥V", action: "Start or stop voice input"),
    Shortcut(keys: "⌘N", action: "New conversation"),
    Shortcut(keys: "⌘O", action: "Open a project"),
    Shortcut(keys: "⌘,", action: "Open Settings"),
    Shortcut(keys: "⌥⌘I", action: "Show or hide the project inspector"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Composer commands and shortcuts").font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("COMMANDS").font(.caption2.weight(.semibold)).foregroundStyle(.themeSecondary)
              .accessibilityAddTraits(.isHeader)
            ForEach(ComposerCommand.allCases) { command in
              row(KeyCap(text: "/\(command.name)"), command.description)
            }
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("SHORTCUTS").font(.caption2.weight(.semibold)).foregroundStyle(.themeSecondary)
              .accessibilityAddTraits(.isHeader)
            ForEach(Self.shortcuts) { shortcut in
              row(KeyCap(text: shortcut.keys), shortcut.action)
            }
          }
          Text("For every other CLI command, use Muse Code in the project inspector to open the full CLI in Terminal.")
            .foregroundStyle(.themeSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Done", action: close)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.primary)
      }
    }
    .padding(20)
    .frame(width: 460, height: 520)
    .onExitCommand(perform: close)
    .accessibilityIdentifier("help-sheet")
  }

  private func row(_ key: KeyCap, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      key.frame(minWidth: 90, alignment: .leading)
      Text(text).foregroundStyle(.themeSecondary)
    }
    .accessibilityElement(children: .combine)
  }
}
