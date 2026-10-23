import Foundation
import MuseBackend
import Testing
@testable import MuseKit

/// A project folder with `src/lib` and `notes.txt`, and a folder beside it, under a new temp folder.
/// The caller deletes `base`.
private func dropFolders() throws -> (base: URL, project: URL, outside: URL) {
  let base = FileManager.default.temporaryDirectory
    .appending(path: "mmac-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
  let project = base.appending(path: "project", directoryHint: .isDirectory)
  let outside = base.appending(path: "outside", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(
    at: project.appending(path: "src/lib", directoryHint: .isDirectory), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try Data("hi".utf8).write(to: project.appending(path: "notes.txt"))
  return (base, project, outside)
}

@Test func aDropAttachesFilesAndMentionsFoldersInsideTheProject() throws {
  let (base, project, outside) = try dropFolders()
  defer { try? FileManager.default.removeItem(at: base) }
  let file = project.appending(path: "notes.txt")
  // A folder URL without the trailing slash is still a folder: the check reads the disk.
  let lib = URL(filePath: project.appending(path: "src/lib").path, directoryHint: .notDirectory)
  let plan = DropPlan.classify(
    [file, project.appending(path: "src", directoryHint: .isDirectory), lib, outside], project: project.path)
  #expect(plan.files == [file])
  #expect(plan.mentions == ["@src/", "@src/lib/"])
  #expect(plan.error == "Drop files, or a folder inside this project.")
}

@Test func onlyFoldersStrictlyInsideTheProjectBecomeMentions() throws {
  let (base, project, _) = try dropFolders()
  defer { try? FileManager.default.removeItem(at: base) }
  let src = project.appending(path: "src", directoryHint: .isDirectory)
  // The project itself is not inside it.
  #expect(DropPlan.classify([project], project: project.path) == DropPlan(error: DropPlan.folderError))
  // With all projects shown, no folder is inside a project.
  #expect(DropPlan.classify([src], project: "") == DropPlan(error: DropPlan.folderError))
  // The temp folder is under a symbolic link (/var → /private/var); both sides are resolved.
  let resolved = project.resolvingSymlinksInPath().path
  #expect(DropPlan.classify([src], project: resolved).mentions == ["@src/"])
  // A folder whose name only starts with the project's name is outside it.
  let sibling = URL(filePath: project.path + "-copy", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
  #expect(DropPlan.classify([sibling], project: project.path).error == DropPlan.folderError)
}

@Test func mentionsGoAtTheEndOfTheDraftAfterOneSpace() {
  let plan = DropPlan(mentions: ["@src/", "@docs/"])
  #expect(plan.appendingMentions(to: "") == "@src/ @docs/")
  #expect(plan.appendingMentions(to: "Look at") == "Look at @src/ @docs/")
  #expect(plan.appendingMentions(to: "Look at ") == "Look at @src/ @docs/")
  #expect(plan.appendingMentions(to: "Look at\n") == "Look at\n@src/ @docs/")
  #expect(DropPlan().appendingMentions(to: "Same") == "Same")
}

@Test func javaScriptWhitespaceIsTheSetTheRegularExpressionsUse() {
  #expect(JSWhitespace.trim(" \t\u{00A0}\u{FEFF}\u{2028}/x\u{3000}\n") == "/x")
  // U+0085 is whitespace to Swift, but not to JavaScript's \s.
  #expect(JSWhitespace.trim("\u{0085}x") == "\u{0085}x")
  #expect(JSWhitespace.endsWithWhitespace("a\u{00A0}"))
  #expect(!JSWhitespace.endsWithWhitespace("a"))
  #expect(!JSWhitespace.endsWithWhitespace(""))
}

@Test func aSymbolicLinkToAFolderIsAFolder() throws {
  let (base, project, outside) = try dropFolders()
  defer { try? FileManager.default.removeItem(at: base) }
  let inside = base.appending(path: "link-in")
  let out = base.appending(path: "link-out")
  try FileManager.default.createSymbolicLink(
    at: inside, withDestinationURL: project.appending(path: "src", directoryHint: .isDirectory))
  try FileManager.default.createSymbolicLink(at: out, withDestinationURL: outside)
  let plan = DropPlan.classify([inside, out], project: project.path)
  #expect(plan.files.isEmpty)
  #expect(plan.mentions == ["@src/"])
  #expect(plan.error == DropPlan.folderError)
}
