import MuseBackend
import Testing
@testable import MuseKit

@Test func diffLinesCarryNumbersAndWorkingHunkIndexes() {
  let diff = """
    Staged changes
    diff --git a/a.txt b/a.txt
    --- a/a.txt
    +++ b/a.txt
    @@ -1,2 +1,2 @@
    -one
    +ONE
     two
    Working changes
    diff --git a/a.txt b/a.txt
    index 1..2 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -5,3 +5,3 @@
     five
    -six
    +SIX
    @@ -20,2 +20,3 @@
     twenty
    +twenty and a half

    """
  let rows = DiffLine.parse(diff)
  #expect(rows.map(\.id) == Array(0..<rows.count))
  #expect(rows.first?.kind == .meta)
  let hunks = rows.filter { $0.kind == .hunk }
  #expect(hunks.map(\.hunkIndex) == [nil, 0, 1])
  let staged = rows[5]
  #expect(staged.kind == .removed && staged.oldNumber == 1 && staged.newNumber == nil && staged.gutter == "1")
  #expect(rows[6].kind == .added && rows[6].newNumber == 1)
  #expect(rows[7].kind == .context && rows[7].oldNumber == 2 && rows[7].newNumber == 2)
  let six = rows.first { $0.text == "+SIX" }
  #expect(six?.newNumber == 6)
  #expect(rows.last?.text == "+twenty and a half")
  #expect(rows.last?.newNumber == 21)
}

@Test func aMissingFinalNewlineMarkerIsMeta() {
  let rows = DiffLine.parse("@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file")
  #expect(rows.last?.kind == .meta)
  #expect(rows.last?.gutter == "")
}

@Test func anUntrackedFilesLinesAreNumberedFromOne() {
  let rows = DiffLine.parse("--- /dev/null\n+++ b/new.txt\n+first\n+second")
  #expect(rows.map(\.kind) == [.meta, .meta, .added, .added])
  #expect(rows.compactMap(\.newNumber) == [1, 2])
}

@Test func linesBeforeAnyHunkHaveNoNumbers() {
  // A message such as "No text diff…" or a binary note is one context row with an empty gutter.
  let rows = DiffLine.parse("No text diff. The file may be binary or its mode changed.")
  #expect(rows.count == 1)
  #expect(rows[0].kind == .context && rows[0].gutter == "")
}

@Test func fileKindsFollowElectronsExtensionLists() {
  #expect(FileKind.of(name: "src", directory: true) == .folder)
  #expect(FileKind.of(name: "App.SWIFT", directory: false) == .code)
  #expect(FileKind.of(name: "main.tsx", directory: false) == .code)
  #expect(FileKind.of(name: "README.md", directory: false) == .document)
  #expect(FileKind.of(name: "package-lock.json", directory: false) == .document)
  #expect(FileKind.of(name: "photo.png", directory: false) == .other)
  #expect(FileKind.of(name: "Makefile", directory: false) == .other)
  #expect(FileKind.of(name: ".swift", directory: false) == .code)
  #expect(Set([FileKind.folder, .code, .document, .other].map(\.symbol)).count == 4)
}

@Test func breadcrumbsWalkFromTheRoot() {
  #expect(Breadcrumb.trail("") == [])
  #expect(Breadcrumb.trail("a/b/c").map(\.path) == ["a", "a/b", "a/b/c"])
  #expect(Breadcrumb.trail("a/b/c").map(\.name) == ["a", "b", "c"])
  #expect(Breadcrumb.parent(of: "a/b/c") == "a/b")
  #expect(Breadcrumb.parent(of: "a") == "")
  #expect(Breadcrumb.parent(of: "") == "")
}

@Test func changeLabelsMatchTheChangedFileRow() {
  #expect(ChangeLabel.status(GitChange(path: "a", status: "??", staged: false)) == "U")
  #expect(ChangeLabel.status(GitChange(path: "a", status: "MM", staged: true)) == "MM")
  #expect(ChangeLabel.isDeleted(GitChange(path: "a", status: "D", staged: true)))
  #expect(!ChangeLabel.isDeleted(GitChange(path: "a", status: "M", staged: false)))
  #expect(ChangeLabel.name("src\\ui\\App.swift") == "App.swift")
  #expect(ChangeLabel.folder("src\\ui\\App.swift") == "src/ui")
  #expect(ChangeLabel.folder("README.md") == "Project root")
}

@Test func gitBadgesSayHowManyChanged() {
  let dirty = GitStatus(branch: "main", changes: [GitChange(path: "a", status: "M", staged: false)], isRepository: true)
  #expect(GitBadge.changes(dirty) == "1 changed")
  #expect(GitBadge.summary(dirty) == "main · 1 changed")
  let clean = GitStatus(branch: "main", changes: [], isRepository: true)
  #expect(GitBadge.changes(clean) == "Clean")
  #expect(GitBadge.summary(GitStatus(branch: "", changes: [], isRepository: false)) == nil)
}

@Test func activityKeepsInternalAndToolItemsWithElectronsLabels() {
  let items = [
    TranscriptItem(itemId: "u", kind: "userMessage", status: "completed"),
    TranscriptItem(itemId: "a", kind: "agentMessage", status: "completed"),
    TranscriptItem(itemId: "r", kind: "reasoning", status: "completed"),
    TranscriptItem(itemId: "x", kind: "toolCall", status: "completed", tool: "shell", retracted: true),
    TranscriptItem(itemId: "t", kind: "toolCall", status: "completed", tool: "shell", statusLine: "ran ls"),
    TranscriptItem(itemId: "c", kind: "reminderChild", status: "inProgress", reminderAgentId: "tidy", blocking: true),
    TranscriptItem(itemId: "b", kind: "reminderChild", status: "completed"),
    TranscriptItem(itemId: "h", kind: "hookRun", status: "failed", label: ""),
    TranscriptItem(itemId: "k", kind: "webSearch", status: "completed", fallbackText: "found it", objective: ""),
  ]
  let entries = ActivityEntry.build(items)
  #expect(entries.map(\.id) == ["t", "c", "b", "h", "k"])
  #expect(entries.map(\.title) == ["shell", "Reminder · tidy", "Background reminder", "CLI hook", "Web Search"])
  #expect(entries.map(\.detail) == ["ran ls", "Keeps the turn open · Running", "completed", "failed", "found it"])
}

@Test func previewLineCountsSplitOnNewlines() {
  #expect(FilePreview.lineCount("a\nb\n") == 3)
  #expect(FilePreview.lineCount("one") == 1)
  #expect(FilePreview.lineCount("") == 1)
  #expect(FilePreview.lineCount("a\r\nb") == 2)
}

@Test func aWindowsFinalNewlineAddsNoEmptyRow() {
  let rows = DiffLine.parse("@@ -1 +1 @@\r\n-a\r\n+b\r\n")
  #expect(rows.count == 3)
  #expect(rows.last?.text == "+b\r")
}
