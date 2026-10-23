import Foundation
import MuseBackend

// The composer's rules: the drop plan, the slash commands and the `@` mentions. Electron keeps
// them in src/renderer/src/commands.ts and components/Composer.tsx.

/// JavaScript's whitespace: what `\s` matches and `String.prototype.trim` removes. The rules
/// ported from Electron's regular expressions use it, so they match the same drafts. Swift's
/// `.whitespacesAndNewlines` differs (it has U+0085, and lacks U+FEFF).
enum JSWhitespace {
  static func contains(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
      true
    default:
      false
    }
  }

  /// `text.trim()`.
  static func trim(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard let first = scalars.firstIndex(where: { !contains($0) }),
      let last = scalars.lastIndex(where: { !contains($0) })
    else { return "" }
    return String(scalars[first...last])
  }

  /// `/\s$/.test(text)`.
  static func endsWithWhitespace(_ text: String) -> Bool {
    text.unicodeScalars.last.map(contains) ?? false
  }
}

/// What a drop on the composer does. Electron pastes a dropped file's text, or `@<file name>`,
/// into the draft. mMac attaches files as chips, with the paperclip's limits, and turns a folder
/// inside the project into a mention of its project-relative path.
public struct DropPlan: Equatable, Sendable {
  public static let folderError = "Drop files, or a folder inside this project."

  /// Files to attach as chips.
  public var files: [URL]
  /// `@<project-relative path>/` for each folder inside the project.
  public var mentions: [String]
  /// Set when a folder is outside the project, is the project itself, or no project is chosen.
  public var error: String?

  public init(files: [URL] = [], mentions: [String] = [], error: String? = nil) {
    self.files = files
    self.mentions = mentions
    self.error = error
  }

  /// Sorts dropped URLs. A folder is told from a file on disk, so a folder URL without its
  /// trailing slash still counts. Both paths have their symbolic links resolved before the
  /// comparison.
  public static func classify(_ urls: [URL], project: String) -> DropPlan {
    var plan = DropPlan()
    let root = project.isEmpty
      ? nil : URL(filePath: project, directoryHint: .isDirectory).resolvingSymlinksInPath().path
    for url in urls where url.isFileURL {
      // Resolved first, so a link to a folder is a folder.
      let resolved = url.resolvingSymlinksInPath()
      let isFolder = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
      guard isFolder else {
        plan.files.append(url)
        continue
      }
      let path = resolved.path
      if let root, path.hasPrefix(root + "/") {
        plan.mentions.append("@\(path.dropFirst(root.count + 1))/")
      } else {
        plan.error = folderError
      }
    }
    return plan
  }

  /// The draft with the mentions at its end, after one space when the draft does not end in
  /// whitespace. The last mention ends in `/`, so the mention menu opens on that folder.
  public func appendingMentions(to draft: String) -> String {
    guard !mentions.isEmpty else { return draft }
    let gap = draft.isEmpty || JSWhitespace.endsWithWhitespace(draft) ? "" : " "
    return draft + gap + mentions.joined(separator: " ")
  }
}
