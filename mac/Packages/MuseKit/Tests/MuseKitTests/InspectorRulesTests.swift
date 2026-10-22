import Foundation
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
  #expect(FilePreview.lineCount("") == 0)
  #expect(FilePreview.lineCount("a\r\nb") == 2)
}

@Test func aWindowsFinalNewlineAddsNoEmptyRow() {
  let rows = DiffLine.parse("@@ -1 +1 @@\r\n-a\r\n+b\r\n")
  #expect(rows.count == 3)
  #expect(rows.last?.text == "+b\r")
}

@Test func removedAndAddedLinesThatLookLikeFileHeadersKeepTheirNumbers() {
  // "-- note" removed is "--- note"; "++ x" added is "+++ x". Inside a hunk they are content.
  let rows = DiffLine.parse("diff --git a/a.sql b/a.sql\n--- a/a.sql\n+++ b/a.sql\n@@ -1,3 +1,3 @@\n--- note\n+++ x\n keep")
  #expect(rows.map(\.kind) == [.meta, .meta, .meta, .hunk, .removed, .added, .context])
  #expect(rows[4].oldNumber == 1 && rows[5].newNumber == 1)
  #expect(rows[6].oldNumber == 2 && rows[6].newNumber == 2)
}

@Test func aNewDiffSectionStartsWithFileHeadersAgain() {
  let rows = DiffLine.parse("@@ -1 +1 @@\n-a\n+b\ndiff --git a/b b/b\n--- a/b\n+++ b/b\n@@ -3 +3 @@\n-c")
  #expect(rows.map(\.kind) == [.hunk, .removed, .added, .meta, .meta, .meta, .hunk, .removed])
  #expect(rows.last?.oldNumber == 3)
}

@Test func aNewFileFlagDoesNotLeakPastADiffLine() {
  // `--- /dev/null` marks one file as new. A `diff ` line starts the next file, which is not.
  let rows = DiffLine.parse("--- /dev/null\ndiff --git a/o b/o\n+++ b/o\n+y")
  #expect(rows.last?.kind == .added)
  #expect(rows.last?.newNumber == nil)
}

@Test func anUntrackedFilesFinalNewlineAddsNoEmptyAddedRow() {
  let rows = DiffLine.parse("--- /dev/null\n+++ b/new.txt\n+first\n+second\n+")
  #expect(rows.map(\.kind) == [.meta, .meta, .added, .added])
  #expect(rows.compactMap(\.newNumber) == [1, 2])
  // An empty untracked file is just the headers and one bare "+".
  #expect(DiffLine.parse("--- /dev/null\n+++ b/e\n+").count == 2)
  // A bare "+" that is a real blank line in a hunk stays.
  let hunk = DiffLine.parse("@@ -0,0 +1,2 @@\n+a\n+")
  #expect(hunk.count == 3 && hunk.last?.newNumber == 2)
}

@Test func anUntrackedFolderShowsWithoutItsTrailingSlash() {
  #expect(ChangeLabel.name("newdir/") == "newdir")
  #expect(ChangeLabel.folder("newdir/") == "Project root")
  #expect(ChangeLabel.name("a/newdir/") == "newdir")
  #expect(ChangeLabel.folder("a/newdir/") == "a")
}

@Test func anUntrackedFilesContentLinesThatLookLikeHeadersKeepTheirNumbers() {
  // `++++ not a header` is the content line `+++ not a header`, as in Hugo front matter.
  let rows = DiffLine.parse("--- /dev/null\n+++ b/notes.md\n+one\n++++ not a header\n+three")
  #expect(rows.map(\.kind) == [.meta, .meta, .added, .added, .added])
  #expect(rows.compactMap(\.newNumber) == [1, 2, 3])
}

@Test func aNewDiffLineDropsTheCountersOfThePreviousHunk() {
  let diff = "Staged changes\n@@ -5,2 +5,2 @@\n-a\n+b\nWorking changes\ndiff --git a/f b/f\nold mode 100644\nBinary files a/f and b/f differ"
  let rows = DiffLine.parse(diff)
  #expect(rows[6].text == "old mode 100644" && rows[6].kind == .context && rows[6].gutter == "")
  #expect(rows[7].gutter == "")
}

@Test func anEmptyLineHasNoNumberAndDoesNotAdvanceTheCounters() {
  // git writes a blank context line as " ". `""` is only the separator between two sections.
  let rows = DiffLine.parse("@@ -1,3 +1,3 @@\n a\n\n b")
  #expect(rows[2].kind == .context && rows[2].gutter == "")
  #expect(rows[3].oldNumber == 2 && rows[3].newNumber == 2)
  let blank = DiffLine.parse("@@ -1,2 +1,2 @@\n a\n  \n b")
  #expect(blank[2].gutter == "2" && blank[3].gutter == "3")
}

@Test func changeStatusesAreSpokenInWords() {
  func spoken(_ status: String) -> String { ChangeLabel.spoken(GitChange(path: "a", status: status, staged: false)) }
  #expect(spoken("??") == "Untracked")
  #expect(spoken("M") == "Modified")
  #expect(spoken("MM") == "Modified")
  #expect(spoken("AM") == "Added and modified")
  #expect(spoken("D") == "Deleted")
  #expect(spoken("R") == "Renamed")
  #expect(spoken("UU") == "Unmerged")
  #expect(spoken("") == "Changed")
}

let reviewDiff = [
  "Working changes",
  "diff --git a/a.swift b/a.swift",
  "index 1..2 100644",
  "--- a/a.swift",
  "+++ b/a.swift",
  "@@ -1,2 +1,2 @@",
  " let a = 1",
  "-let b = 2",
  "+let b = 3",
  "\\ No newline at end of file",
  "@@ -9 +9 @@",
  "+",
].joined(separator: "\n")

@Test func diffRowsAreSpokenWithTheirKindAndLine() {
  let rows = DiffLine.parse(reviewDiff)
  #expect(rows.map(\.spoken) == [
    "Working changes",
    "diff --git a/a.swift b/a.swift",
    "index 1..2 100644",
    "--- a/a.swift",
    "+++ b/a.swift",
    "Hunk, @@ -1,2 +1,2 @@",
    "Line 1, let a = 1",
    "Removed, line 2, let b = 2",
    "Added, line 2, let b = 3",
    "\\ No newline at end of file",
    "Hunk, @@ -9 +9 @@",
    "Added, line 9, blank",
  ])
  #expect(DiffLine.parse("+x").first?.spoken == "Added, x")
}

@Test func aDiffAndAHunkCopyAsTextWithoutGutters() {
  let rows = DiffLine.parse(reviewDiff)
  #expect(DiffLine.text(rows) == reviewDiff)
  #expect(DiffLine.hunkText(rows, at: 5) == "@@ -1,2 +1,2 @@\n let a = 1\n-let b = 2\n+let b = 3\n\\ No newline at end of file")
  #expect(DiffLine.hunkText(rows, at: 10) == "@@ -9 +9 @@\n+")
  // A hunk ends at the next file, and at the blank line between the staged and working sections.
  let sections = DiffLine.parse("Staged changes\n@@ -1 +1 @@\n-a\n+b\n\nWorking changes\n@@ -1 +1 @@\n-b\n+c")
  #expect(DiffLine.hunkText(sections, at: 1) == "@@ -1 +1 @@\n-a\n+b")
  let files = DiffLine.parse("@@ -1 +1 @@\n-a\n+b\ndiff --git a/c b/c\n@@ -1 +1 @@\n-c")
  #expect(DiffLine.hunkText(files, at: 0) == "@@ -1 +1 @@\n-a\n+b")
  // Not a hunk header: nothing.
  #expect(DiffLine.hunkText(rows, at: 6) == "")
}

@Test func diffMetricsGiveTheWidestNumberAndLine() {
  let rows = DiffLine.parse("@@ -98,3 +99,3 @@\n a\n-bb\n+\t\tc\n d")
  // Lines 99 to 101: three digits. "+\t\tc" is one column, two tabs of eight, and one more: 18,
  // longer than the 17-column hunk header.
  #expect(DiffLine.metrics(rows) == DiffLine.Metrics(maxDigits: 3, maxColumns: 18))
  #expect(DiffLine.metrics([]) == DiffLine.Metrics(maxDigits: 0, maxColumns: 0))
  #expect(DiffLine.metrics(DiffLine.parse("plain")) == DiffLine.Metrics(maxDigits: 0, maxColumns: 5))
}

@Test func rawHunksMatchTheBackendsSplit() {
  let raw =
    "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n-one\n+ONE\n two\n@@ -9 +9 @@\n-nine\n+NINE\n"
  #expect(DiffLine.rawHunks(raw) == ["@@ -1,2 +1,2 @@\n-one\n+ONE\n two", "@@ -9 +9 @@\n-nine\n+NINE"])
  let noNewline = "--- a/b\n+++ b/b\n@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n"
  #expect(DiffLine.rawHunks(noNewline) == ["@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file"])
  #expect(DiffLine.rawHunks("Binary files differ\n").isEmpty)
  #expect(DiffLine.rawHunks("").isEmpty)
  // Only one final newline goes, as `replace(/\n$/, '')`.
  #expect(DiffLine.rawHunks("@@ -1 +1 @@\n+a\n\n") == ["@@ -1 +1 @@\n+a\n"])
}

/// The bytes Git wrote for a file with Windows line ends, kept byte-exact beside the backend's
/// test of the same diff. `splitHunks` splits on "\n" only, so each line keeps its "\r".
@Test func rawHunksOfAWindowsFileKeepEachCarriageReturn() throws {
  let url = try #require(
    Bundle.module.url(forResource: "crlf-two-hunks", withExtension: "diff", subdirectory: "Fixtures"))
  let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
  let hunks = DiffLine.rawHunks(raw)
  let expected = [
    "@@ -1,5 +1,5 @@\n one\r\n-two\r\n+TWO\r\n three\r\n x\r\n x\r",
    "@@ -22,4 +22,5 @@ x\n x\r\n x\r\n ten\r\n+ten and a half\r\n eleven\r",
  ]
  // Compared as bytes, so every "\r" is checked exactly.
  #expect(hunks.map { Array($0.utf8) } == expected.map { Array($0.utf8) })
  // The parsed diff numbers the same two hunks, so a row's `hunkIndex` picks the matching text.
  let rows = DiffLine.parse("Working changes\n" + raw)
  #expect(rows.compactMap(\.hunkIndex) == [0, 1])
  #expect(rows.last?.text == " eleven\r")
}

@Test func longDiffLinesShowCut() {
  let long = String(repeating: "x", count: 2_500)
  let shown = DiffLine.display(long)
  #expect(shown.count == DiffLine.longLine + 1 && shown.hasSuffix("…"))
  #expect(DiffLine.display(String(repeating: "y", count: DiffLine.longLine)).count == DiffLine.longLine)
  #expect(DiffLine.display("short") == "short")
  // The view is as wide as the cut line; Copy hunk and Copy diff keep the whole line.
  let rows = DiffLine.parse("@@ -1 +1 @@\n+" + long)
  #expect(DiffLine.metrics(rows).maxColumns == DiffLine.longLine + 1)
  #expect(DiffLine.text(rows).hasSuffix(long))
  #expect(DiffLine.hunkText(rows, at: 0).hasSuffix(long))
}

@Test func tabTitlesCountOnlyWhenThereIsSomething() {
  #expect(ChangeLabel.counted("Changes", 0) == "Changes")
  #expect(ChangeLabel.counted("Changes", 3) == "Changes 3")
}
