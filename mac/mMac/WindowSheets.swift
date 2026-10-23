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

  /// Opens the Rename sheet on `session`'s name, or on its sidebar title when it has none.
  func rename(_ session: Session) {
    rename(title: session.name ?? SessionTitle.of(session))
  }

  /// Opens the Rename sheet with `title` in its field, as `/rename` with no name does.
  func rename(title: String) {
    newName = title
    renaming = true
  }
}
