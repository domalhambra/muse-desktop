import Foundation
import MuseBackend

// Pins, archives and the Markdown export. Electron's versions are `togglePin`, `toggleArchive` and
// the Export as Markdown button in src/renderer/src/App.tsx, and the `export` handler in
// src/main/index.ts.
extension Workspace {
  public func isPinned(_ sessionId: String) -> Bool { preferences.pinnedSessionIds.contains(sessionId) }

  /// Decides the Archive or Restore label: the conversation's own state, not the sidebar's view.
  public func isArchived(_ sessionId: String) -> Bool { preferences.archivedSessionIds.contains(sessionId) }

  /// Pins or unpins a conversation. Returns false when the save failed.
  @discardableResult
  public func togglePin(_ sessionId: String) async -> Bool {
    await toggle(sessionId, in: .pinned)
  }

  /// Archives or restores a conversation in mMac only; the CLI session is untouched. Archiving or
  /// restoring the open conversation returns to New conversation, as Electron does. Returns false
  /// when the save failed.
  @discardableResult
  public func toggleArchive(_ sessionId: String) async -> Bool {
    guard await toggle(sessionId, in: .archived) else { return false }
    // A click on another conversation made while the save ran is pending in `openingSessionId`;
    // it must not be undone.
    if (openingSessionId ?? view?.session.sessionId) == sessionId { startNew() }
    return true
  }

  enum SavedList { case pinned, archived }

  /// Saves the list with `sessionId` added at the end, or removed. Each toggle waits for the one
  /// before it and reads `preferences` only then, so two quick toggles both land. Electron
  /// computes both from the state before the first reply, and the first is lost.
  private func toggle(_ sessionId: String, in list: SavedList) async -> Bool {
    let previous = preferenceToggles
    let next = Task { [weak self] () -> Bool in
      _ = await previous?.value
      guard let self else { return false }
      let ids = list == .pinned ? preferences.pinnedSessionIds : preferences.archivedSessionIds
      let changed = ids.contains(sessionId) ? ids.filter { $0 != sessionId } : ids + [sessionId]
      let patch =
        list == .pinned ? PreferencesPatch(pinnedSessionIds: changed) : PreferencesPatch(archivedSessionIds: changed)
      return await save(patch)
    }
    preferenceToggles = next
    return await next.value
  }

  /// Exports the open conversation to `url`, chosen in the save panel. The backend writes
  /// Electron's format, mode 0600. Success shows the notice and returns true.
  @discardableResult
  public func exportConversation(to url: URL) async -> Bool {
    guard let session = view?.session else { return false }
    do {
      _ = try await client.export(
        sessionId: session.sessionId, to: url, fallbackTitle: ExportName.fallbackTitle(for: session))
      showNotice("Conversation exported to Markdown.")
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}

/// The export's title and the save panel's default file name, as Electron's `export` handler
/// makes them, with the sidebar title as a fallback.
public enum ExportName {
  /// The sidebar's first-prompt title, for a conversation with neither name nor title. Electron
  /// writes "Muse conversation" there; mMac uses what the sidebar shows. Nil for "Untitled
  /// conversation", so the backend falls through to "Muse conversation".
  public static func fallbackTitle(for session: Session) -> String? {
    let title = SessionTitle.text(name: nil, title: nil, firstUserPrompt: session.firstUserPrompt)
    return title == "Untitled conversation" ? nil : title
  }

  /// `name`, then `title`, then the fallback, then "Muse conversation". An empty value is skipped,
  /// as JavaScript's `||` skips it; name and title are used raw, as Electron uses them.
  public static func title(for session: Session) -> String {
    [session.name, session.title, fallbackTitle(for: session)].compactMap { $0 }.first { !$0.isEmpty }
      ?? "Muse conversation"
  }

  /// Electron's `title.replace(/[^\p{L}\p{N} _-]/gu, '').slice(0, 80) + '.md'`, except that the cut
  /// never splits a surrogate pair. A stem left empty or blank after the cleanup becomes "Muse
  /// conversation", and the stem is trimmed (Electron would give ".md" or a name with edge spaces).
  public static func defaultFileName(for session: Session) -> String {
    var kept = String.UnicodeScalarView()
    var units = 0
    for scalar in title(for: session).unicodeScalars where keeps(scalar) {
      let width = UTF16.width(scalar)
      if units + width > 80 { break }
      kept.append(scalar)
      units += width
    }
    let stem = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
    return (stem.isEmpty ? "Muse conversation" : stem) + ".md"
  }

  /// Letters (`\p{L}`), numbers (`\p{N}`), space, `_` and `-`.
  static func keeps(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
      .decimalNumber, .letterNumber, .otherNumber:
      true
    default:
      scalar == " " || scalar == "_" || scalar == "-"
    }
  }
}
