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

// Composer commands (src/renderer/src/commands.ts and Composer.tsx).

@Test func theTenCommandsKeepElectronsOrderAndDescriptions() {
  #expect(ComposerCommand.allCases.map(\.name) == [
    "clear", "new", "voice", "model", "effort", "compact", "rename", "stop", "settings", "help", "btw",
  ])
  #expect(ComposerCommand.allCases.map(\.description) == [
    "Start a new conversation; keep saved history",
    "Start a new conversation",
    "Start voice input",
    "Choose a model, or /model <model-id>",
    "Choose reasoning effort, or /effort <level>",
    "Compact this conversation with Muse Code",
    "/rename <conversation name>",
    "Stop Muse\u{2019}s active turn",
    "Open desktop settings",
    "Open the guide and CLI compatibility information",
    "Ask a side question that leaves this conversation untouched",
  ])
}

/// The M4b live run counted 10 rows in the popup and 11 in Help. Both read `allCases`: the slash
/// popup's full list (`menu(for: "/")`) and the Help sheet's list (HelpSheet.swift) are the same
/// eleven, `/btw` last. Electron's 290-point cap fit exactly ten rows, which hid `/btw`; the popup
/// is now capped at 306 points, so half of `/btw`'s row shows and hints that the list scrolls.
@Test func thePopupAndTheHelpSheetListTheSameCommands() {
  #expect(ComposerCommand.menu(for: "/") == ComposerCommand.allCases)
  #expect(ComposerCommand.menu(for: "/").last == .btw)
  #expect(ComposerCommand.menu(for: "/b") == [.btw])
}

@Test func theMenuOpensOnlyForASlashAndLettersOnTheWholeDraft() {
  #expect(ComposerCommand.menu(for: "/").count == 11)
  #expect(ComposerCommand.menu(for: "/mo") == [.model])
  #expect(ComposerCommand.menu(for: "/Model") == [.model])
  #expect(ComposerCommand.menu(for: "/MO") == [.model])
  #expect(ComposerCommand.menu(for: "/c") == [.clear, .compact])
  #expect(ComposerCommand.menu(for: "/n") == [.new])
  #expect(ComposerCommand.menu(for: "/vo") == [.voice])
  #expect(ComposerCommand.menu(for: "/x").isEmpty)
  #expect(ComposerCommand.menu(for: "/model ").isEmpty)
  #expect(ComposerCommand.menu(for: "/model x").isEmpty)
  #expect(ComposerCommand.menu(for: " /mo").isEmpty)
  #expect(ComposerCommand.menu(for: "hi /mo").isEmpty)
  // Shift-Return adds a newline, and the menu closes: JavaScript's `$` does not match before it.
  #expect(ComposerCommand.menu(for: "/mo\n").isEmpty)
  #expect(ComposerCommand.menu(for: "/m\u{00E9}").isEmpty)
  #expect(ComposerCommand.menu(for: "").isEmpty)
}

@Test func parsingTrimsTheDraftLowercasesTheNameAndTrimsTheArgument() {
  #expect(ComposerCommand.parse("/effort medium") == ParsedCommand(name: "effort", argument: "medium"))
  #expect(ComposerCommand.parse("  /Rename   a\nb  ") == ParsedCommand(name: "rename", argument: "a\nb"))
  #expect(ComposerCommand.parse("/model\tm1") == ParsedCommand(name: "model", argument: "m1"))
  #expect(ComposerCommand.parse("/clear") == ParsedCommand(name: "clear", argument: ""))
  #expect(ComposerCommand.parse("/a-b") == ParsedCommand(name: "a-b", argument: ""))
  // Any /word parses, so a CLI command never reaches Muse as a message.
  #expect(ComposerCommand.parse("/tmp") == ParsedCommand(name: "tmp", argument: ""))
  #expect(ComposerCommand.parse("/etc is broken") == ParsedCommand(name: "etc", argument: "is broken"))
  #expect(ComposerCommand.parse("\u{00A0}/stop\u{FEFF}") == ParsedCommand(name: "stop", argument: ""))
  #expect(ComposerCommand.parse("/etc/hosts is odd") == nil)
  #expect(ComposerCommand.parse("/") == nil)
  #expect(ComposerCommand.parse("hello /stop") == nil)
  #expect(ComposerCommand.parse("/stop!") == nil)
  #expect(ComposerCommand.parse("") == nil)
}

@Test func theArrowsWrapAndTabFillsTheHighlightedCommand() {
  // "/c" lists clear and compact.
  #expect(ComposerCommand.slashKeyAction(.down, draft: "/c", index: 0) == .select(1))
  #expect(ComposerCommand.slashKeyAction(.down, draft: "/c", index: 1) == .select(0))
  #expect(ComposerCommand.slashKeyAction(.up, draft: "/c", index: 0) == .select(1))
  #expect(ComposerCommand.slashKeyAction(.up, draft: "/c", index: 1) == .select(0))
  #expect(ComposerCommand.slashKeyAction(.tab, draft: "/c", index: 1) == .setDraft("/compact "))
  #expect(ComposerCommand.slashKeyAction(.tab, draft: "/vo", index: 0) == .setDraft("/voice "))
}

@Test func enterFillsAPrefixButRunsAWholeName() {
  #expect(ComposerCommand.slashKeyAction(.enter, draft: "/m", index: 0) == .setDraft("/model "))
  #expect(ComposerCommand.slashKeyAction(.enter, draft: "/n", index: 0) == .setDraft("/new "))
  #expect(ComposerCommand.slashKeyAction(.enter, draft: "/model", index: 0) == .submit)
  #expect(ComposerCommand.slashKeyAction(.enter, draft: "/MODEL", index: 0) == .submit)
  #expect(ComposerCommand.slashKeyAction(.enter, draft: "/clear", index: 0) == .submit)
}

@Test func escapeAddsASpaceAndAClosedMenuPassesKeysOn() {
  #expect(ComposerCommand.slashKeyAction(.escape, draft: "/mo", index: 0) == .setDraft("/mo "))
  #expect(ComposerCommand.slashKeyAction(.enter, draft: "/model ", index: 0) == .pass)
  #expect(ComposerCommand.slashKeyAction(.tab, draft: "hello", index: 0) == .pass)
  #expect(ComposerCommand.slashKeyAction(.down, draft: "/x", index: 0) == .pass)
}

// The `@` rule (Composer.tsx).

@Test func aMentionIsAnAtSignThatStartsTheDraftOrFollowsWhitespace() {
  #expect(MentionRule.match("@") == Mention(prefix: "", token: "", directory: "", filter: ""))
  #expect(MentionRule.match("see @src/ma") == Mention(prefix: "see ", token: "src/ma", directory: "src", filter: "ma"))
  #expect(MentionRule.match("x @a/b/c") == Mention(prefix: "x ", token: "a/b/c", directory: "a/b", filter: "c"))
  #expect(MentionRule.match("x @src/") == Mention(prefix: "x ", token: "src/", directory: "src", filter: ""))
  #expect(MentionRule.match("line\n@Fi") == Mention(prefix: "line\n", token: "Fi", directory: "", filter: "Fi"))
  #expect(MentionRule.match("a\u{00A0}@x")?.token == "x")
  #expect(MentionRule.match("a@b") == nil)
  #expect(MentionRule.match("@a b") == nil)
  #expect(MentionRule.match("@a@b") == nil)
  #expect(MentionRule.match("@@") == nil)
  #expect(MentionRule.match("no mention") == nil)
}

@Test func rowsMatchTheNameAnyCaseAndStopAt12() {
  let entries = (1...20).map { ProjectFile(name: "File\($0).swift", path: "src/File\($0).swift", directory: false) }
    + [ProjectFile(name: "README.md", path: "README.md", directory: false)]
  #expect(MentionRule.rows(entries, filter: "").count == 12)
  #expect(MentionRule.rows(entries, filter: "readme").map(\.path) == ["README.md"])
  #expect(MentionRule.rows(entries, filter: "FILE1").map(\.name) == [
    "File1.swift", "File10.swift", "File11.swift", "File12.swift", "File13.swift", "File14.swift",
    "File15.swift", "File16.swift", "File17.swift", "File18.swift", "File19.swift",
  ])
  // The path is not searched, only the name.
  #expect(MentionRule.rows(entries, filter: "src").isEmpty)
}

@Test func aFileInsertsItsPathAndASpaceAndAFolderItsPathAndASlash() {
  let file = ProjectFile(name: "main.swift", path: "src/main.swift", directory: false)
  let folder = ProjectFile(name: "lib", path: "src/lib", directory: true)
  #expect(MentionRule.insert(file, into: "see @src/ma") == "see @src/main.swift ")
  #expect(MentionRule.insert(folder, into: "see @src/") == "see @src/lib/")
  #expect(MentionRule.insert(file, into: "@") == "@src/main.swift ")
  #expect(MentionRule.insert(file, into: "no mention") == "no mention")
}

@Test func mentionKeysWrapChooseAndDismiss() {
  #expect(MentionRule.keyAction(.down, index: 2, count: 3) == .select(0))
  #expect(MentionRule.keyAction(.up, index: 0, count: 3) == .select(2))
  #expect(MentionRule.keyAction(.tab, index: 1, count: 3) == .choose(1))
  #expect(MentionRule.keyAction(.enter, index: 2, count: 3) == .choose(2))
  #expect(MentionRule.keyAction(.escape, index: 0, count: 3) == .dismiss)
  #expect(MentionRule.keyAction(.enter, index: 0, count: 0) == .pass)
}

@Test func theFourModesKeepMusesOrderAndNames() {
  #expect(ApprovalMode.allCases.map(\.rawValue) == ["allowAll", "promptUnmatched", "onRequest", "denyUnmatched"])
  #expect(ApprovalMode.allCases.map(\.label) == ["Allow all", "Prompt unmatched", "On request", "Deny unmatched"])
  #expect(ApprovalMode.label(for: "onRequest") == "On request")
  #expect(ApprovalMode.label(for: "futureMode") == "futureMode")
}

@Test func aBangDraftIsAShellCommandAndABangInsideTextIsNot() {
  #expect(ShellRule.command(in: "!echo hi") == "echo hi")
  #expect(ShellRule.command(in: "  ! ls -la  ") == "ls -la")
  #expect(ShellRule.command(in: "!") == nil)
  #expect(ShellRule.command(in: "Say hi!") == nil)
  #expect(ShellRule.command(in: "") == nil)
}
