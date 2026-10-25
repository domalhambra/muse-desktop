import MuseBackend
import MuseKit
import Observation

/// The sheets that more than one place opens: the menu bar, the sidebar's context menu, the
/// toolbar and the composer. AppController owns it, so a menu command reaches it too.
@MainActor @Observable
final class WindowSheets {
  /// The Rename sheet, for the open conversation.
  var renaming = false
  /// The Rename sheet's field.
  var newName = ""
  /// The ⌘K sheet.
  var commandMenu = false
  /// The Help sheet that /help opens.
  var help = false
  /// The side chat sheet (⌘;).
  var sideChat = false
  /// The child session sheet (a subagent, from the Agents tab).
  var child = false
  /// The Proposed changes sheet: the project's change cards, from the sidebar.
  var proposedChanges = false
  /// The result chosen in the ⌘K sheet. The window runs it once the sheet has closed, so a panel
  /// it opens attaches to the window, not to the closing sheet.
  var chosen: CommandMenuAction?

  /// Opens the Rename sheet on `session`'s name, or on its sidebar title when it has none.
  func rename(_ session: Session) {
    rename(title: session.name ?? SessionTitle.of(session))
  }

  /// Opens the Rename sheet with `title` in its field, as `/rename` with no name does.
  func rename(title: String) {
    newName = title
    renaming = true
  }

  /// True while one of these sheets shows on the main window.
  var anyShown: Bool { renaming || commandMenu || help || sideChat || child || proposedChanges }
}
