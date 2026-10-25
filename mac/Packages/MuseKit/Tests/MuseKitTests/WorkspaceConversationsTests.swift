import Foundation
import MuseBackend
import MuseBackendTesting
import Synchronization
import Testing
@testable import MuseKit

/// The backend's preferences file: each patch merges into it, and the reply is the whole set.
private final class SavedPreferences: Sendable {
  private let state = Mutex<[String: JSONValue]>(["recentProjects": ["/p"]])

  func save(_ args: [JSONValue]) -> String {
    guard case .object(let patch)? = args.first else { return "null" }
    return state.withLock { saved in
      saved.merge(patch) { _, new in new }
      return String(decoding: try! JSONEncoder().encode(JSONValue.object(saved)), as: UTF8.self)
    }
  }
}

/// Answers `preferences` from `saved`, `open` with s1 (first prompt "Fix the   bug"), `export`
/// with a path, and the rest with null.
private func conversationScript(_ saved: SavedPreferences) -> @Sendable (String, [JSONValue], Int) -> [String] {
  { method, args, id in
    switch method {
    case "preferences": [reply(id, saved.save(args))]
    case "open": [reply(id, viewJSON(sessionJSON("s1", firstUserPrompt: "Fix the   bug")))]
    case "export": [reply(id, #""/x/out.md""#)]
    default: [reply(id, "null")]
    }
  }
}

/// The ids of every `preferences` request, in order.
private func preferenceIds(_ backend: ScriptedBackend) -> [Int] {
  backend.messages.compactMap { message in
    guard message["method"] == "preferences", case .number(let id)? = message["id"] else { return nil }
    return Int(id)
  }
}

/// The arguments of the last `export` request.
private func exportArgs(_ backend: ScriptedBackend) -> [JSONValue]? {
  guard case .array(let args)? = backend.messages.last(where: { $0["method"] == "export" })?["args"] else {
    return nil
  }
  return args
}

@MainActor @Test func pinningAddsAtTheEndAndUnpinningRemoves() async throws {
  let (workspace, backend) = await makeWorkspace(script: conversationScript(SavedPreferences()))
  #expect(await workspace.togglePin("a"))
  #expect(await workspace.togglePin("b"))
  #expect(workspace.preferences.pinnedSessionIds == ["a", "b"])
  #expect(workspace.isPinned("a"))
  #expect(await workspace.togglePin("a"))
  #expect(workspace.preferences.pinnedSessionIds == ["b"])
  #expect(!workspace.isPinned("a"))
  #expect(requests(backend).map { $0[1] } == [
    [["pinnedSessionIds": ["a"]]], [["pinnedSessionIds": ["a", "b"]]], [["pinnedSessionIds": ["b"]]],
  ])
}

@MainActor @Test func twoQuickTogglesBothLand() async throws {
  // `preferences` gets no answer until the test pushes one.
  let (workspace, backend) = await makeWorkspace { _, _, _ in [] }
  let first = Task { await workspace.togglePin("a") }
  try await eventually { preferenceIds(backend).count == 1 }
  let second = Task { await workspace.togglePin("b") }
  // The second toggle waits for the first reply, so it reads the list that reply brings.
  try await Task.sleep(for: .milliseconds(50))
  #expect(preferenceIds(backend).count == 1)
  backend.push(reply(preferenceIds(backend)[0], #"{"recentProjects":["/p"],"pinnedSessionIds":["a"]}"#))
  try await eventually { preferenceIds(backend).count == 2 }
  #expect(requests(backend).last == ["preferences", [["pinnedSessionIds": ["a", "b"]]]])
  backend.push(reply(preferenceIds(backend)[1], #"{"recentProjects":["/p"],"pinnedSessionIds":["a","b"]}"#))
  #expect(await first.value)
  #expect(await second.value)
  #expect(workspace.preferences.pinnedSessionIds == ["a", "b"])
}

@MainActor @Test func archivingOrRestoringTheOpenConversationStartsANewOne() async throws {
  let (workspace, _) = await makeWorkspace(script: conversationScript(SavedPreferences()))
  await workspace.open("s1")
  #expect(await workspace.toggleArchive("other"))
  #expect(workspace.view?.session.sessionId == "s1")
  #expect(await workspace.toggleArchive("s1"))
  #expect(workspace.view == nil)
  #expect(workspace.isArchived("s1"))
  // Restoring it from the archived view also returns to a new conversation, in the normal list.
  await workspace.open("s1")
  workspace.showArchived = true
  #expect(await workspace.toggleArchive("s1"))
  #expect(workspace.view == nil)
  #expect(!workspace.showArchived)
  #expect(workspace.preferences.archivedSessionIds == ["other"])
}

@MainActor @Test func aFailedToggleShowsTheErrorAndKeepsTheConversation() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "open": [reply(id, viewJSON(sessionJSON("s1")))]
    case "preferences": [failure(id, "EACCES: permission denied")]
    default: [reply(id, "null")]
    }
  }
  await workspace.open("s1")
  #expect(await workspace.toggleArchive("s1") == false)
  #expect(workspace.view?.session.sessionId == "s1")
  #expect(workspace.errorMessage == "EACCES: permission denied")
}

@MainActor @Test func startingANewConversationLeavesTheArchivedView() async {
  let (workspace, _) = await makeWorkspace()
  workspace.showArchived = true
  workspace.startNew()
  #expect(!workspace.showArchived)
  // Choosing a project starts a new conversation too, as Electron's switcher does.
  workspace.showArchived = true
  workspace.selectProject("/q")
  #expect(!workspace.showArchived)
}

@MainActor @Test func theSidebarFollowsThePinsAndTheArchivedView() async throws {
  let list = #"{"sessions":[\#(sessionJSON("a", updatedAt: "2026-10-21T10:00:00Z")),\#(sessionJSON("b", updatedAt: "2026-10-21T09:00:00Z")),\#(sessionJSON("c", updatedAt: "2026-10-21T08:00:00Z"))],"nextCursor":null}"#
  let (workspace, _) = await makeWorkspace(
    preferences: Preferences(recentProjects: ["/p"], pinnedSessionIds: ["c"], archivedSessionIds: ["b"])
  ) { method, _, id in method == "sessions" ? [reply(id, list)] : [] }
  await workspace.refreshSessions()
  #expect(workspace.sections.first?.title == "Pinned")
  #expect(workspace.sections.flatMap { $0.sessions.map(\.sessionId) } == ["c", "a"])
  workspace.showArchived = true
  #expect(workspace.sections.flatMap { $0.sessions.map(\.sessionId) } == ["b"])
}

@MainActor @Test func exportSendsTheSidebarTitleAsTheFallbackAndShowsTheNotice() async throws {
  let (workspace, backend) = await makeWorkspace(script: conversationScript(SavedPreferences()))
  await workspace.open("s1")
  #expect(await workspace.exportConversation(to: URL(fileURLWithPath: "/x/out.md")))
  #expect(exportArgs(backend) == ["s1", "/x/out.md", "Fix the bug"])
  #expect(workspace.notice == "Conversation exported to Markdown.")
  #expect(workspace.noticeCount == 1)
  #expect(workspace.errorMessage == nil)
}

@MainActor @Test func anUntitledConversationSendsNoFallback() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "open": [reply(id, viewJSON(sessionJSON("s1")))]
    case "export": [reply(id, #""/x/out.md""#)]
    default: [reply(id, "null")]
    }
  }
  await workspace.open("s1")
  #expect(await workspace.exportConversation(to: URL(fileURLWithPath: "/x/out.md")))
  #expect(exportArgs(backend) == ["s1", "/x/out.md"])
}

@MainActor @Test func aFailedExportShowsTheErrorAndNoNotice() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "open": [reply(id, viewJSON(sessionJSON("s1")))]
    case "export": [failure(id, "Open this conversation before performing an action.")]
    default: [reply(id, "null")]
    }
  }
  await workspace.open("s1")
  #expect(await workspace.exportConversation(to: URL(fileURLWithPath: "/x/out.md")) == false)
  #expect(workspace.errorMessage == "Open this conversation before performing an action.")
  #expect(workspace.notice == nil)
}

@MainActor @Test func exportWithNoConversationSendsNothing() async {
  let (workspace, backend) = await makeWorkspace()
  #expect(await workspace.exportConversation(to: URL(fileURLWithPath: "/x/out.md")) == false)
  #expect(backend.messages.isEmpty)
}

@MainActor @Test func anExportForAConversationNoLongerOpenSendsNothing() async throws {
  let (workspace, backend) = await makeWorkspace { method, args, id in
    guard case .string(let sessionId)? = args.first else { return [reply(id, "null")] }
    return switch method {
    case "open": [reply(id, viewJSON(sessionJSON(sessionId)))]
    case "export": [reply(id, #""/x/out.md""#)]
    default: [reply(id, "null")]
    }
  }
  await workspace.open("s1")
  await workspace.open("s2")
  #expect(await workspace.exportConversation(to: URL(fileURLWithPath: "/x/out.md"), sessionId: "s1") == false)
  #expect(exportArgs(backend) == nil)
  #expect(workspace.errorMessage == nil)
  #expect(workspace.notice == nil)
}

@MainActor @Test func anExportForTheOpenConversationWrites() async throws {
  let (workspace, backend) = await makeWorkspace(script: conversationScript(SavedPreferences()))
  await workspace.open("s1")
  #expect(await workspace.exportConversation(to: URL(fileURLWithPath: "/x/out.md"), sessionId: "s1"))
  #expect(exportArgs(backend)?.first == "s1")
}

@MainActor @Test func everyNoticeCounts() async {
  let (workspace, _) = await makeWorkspace()
  workspace.showNotice("Done.")
  workspace.showNotice("Done.")
  #expect(workspace.notice == "Done.")
  #expect(workspace.noticeCount == 2)
}

@Test func theDefaultFileNameKeepsLettersDigitsSpacesUnderscoresAndHyphens() {
  // The survey's worked example.
  let example = Session(sessionId: "s", updatedAt: "x", name: #"Fix: the "bug" / ok 🎉"#)
  #expect(ExportName.defaultFileName(for: example) == "Fix the bug  ok .md")
  #expect(ExportName.defaultFileName(for: Session(sessionId: "s", updatedAt: "x", title: "A.b/c_d-e")) == "Abc_d-e.md")
  // Name wins over title.
  #expect(ExportName.defaultFileName(for: Session(sessionId: "s", updatedAt: "x", name: "N", title: "T")) == "N.md")
  // Unicode letters and digits stay: \p{L} and \p{N}.
  #expect(ExportName.defaultFileName(for: Session(sessionId: "s", updatedAt: "x", name: "Ünïcödé 名前 ٣")) == "Ünïcödé 名前 ٣.md")
  // A title the cleanup empties or leaves blank falls back to "Muse conversation" (Electron gives ".md").
  #expect(ExportName.defaultFileName(for: Session(sessionId: "s", updatedAt: "x", name: "🎉!!")) == "Muse conversation.md")
  #expect(ExportName.defaultFileName(for: Session(sessionId: "s", updatedAt: "x", name: "   ")) == "Muse conversation.md")
  #expect(ExportName.defaultFileName(for: Session(sessionId: "s", updatedAt: "x", name: " 🎉 ")) == "Muse conversation.md")
  // Any other stem keeps its edge spaces, as Electron does.
  #expect(ExportName.defaultFileName(for: Session(sessionId: "s", updatedAt: "x", name: "!! Hi !!")) == " Hi .md")
}

@Test func theTitleFallsBackToTheFirstPromptThenMuseConversation() {
  let prompt = Session(sessionId: "s", updatedAt: "x", firstUserPrompt: "  Plan the   trip  ")
  #expect(ExportName.fallbackTitle(for: prompt) == "Plan the trip")
  #expect(ExportName.title(for: prompt) == "Plan the trip")
  #expect(ExportName.defaultFileName(for: prompt) == "Plan the trip.md")
  let empty = Session(sessionId: "s", updatedAt: "x")
  #expect(ExportName.fallbackTitle(for: empty) == nil)
  #expect(ExportName.title(for: empty) == "Muse conversation")
  #expect(ExportName.defaultFileName(for: empty) == "Muse conversation.md")
  // An empty name is skipped, as JavaScript's `||` skips it.
  #expect(ExportName.title(for: Session(sessionId: "s", updatedAt: "x", name: "", title: "T")) == "T")
}

@Test func theFileNameIsCutAt80UTF16UnitsWithoutSplittingAPair() {
  let long = Session(sessionId: "s", updatedAt: "x", name: String(repeating: "é", count: 100))
  #expect(ExportName.defaultFileName(for: long) == String(repeating: "é", count: 80) + ".md")
  // 𝐀 (U+1D400) is a letter of two UTF-16 units. At 79 units it does not fit, so it is left out.
  let pair = Session(sessionId: "s", updatedAt: "x", name: String(repeating: "a", count: 79) + "𝐀")
  #expect(ExportName.defaultFileName(for: pair) == String(repeating: "a", count: 79) + ".md")
  let fits = Session(sessionId: "s", updatedAt: "x", name: String(repeating: "a", count: 78) + "𝐀")
  #expect(ExportName.defaultFileName(for: fits) == String(repeating: "a", count: 78) + "𝐀.md")
}

@MainActor @Test func anArchiveNeverUndoesAClickOnAnotherConversation() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "open": [] // held: the test answers
    case "preferences": []
    default: [reply(id, "null")]
    }
  }
  func id(_ name: String) -> Int? {
    backend.messages.compactMap { m -> Int? in
      guard m["method"] == .string(name), case .number(let n)? = m["id"] else { return nil }
      return Int(n)
    }.last
  }
  let openA = Task { await workspace.open("A") }
  try await eventually { id("open") != nil }
  backend.push(reply(id("open")!, viewJSON(sessionJSON("A"))))
  await openA.value
  let archive = Task { await workspace.toggleArchive("A") }
  try await eventually { id("preferences") != nil }
  let openB = Task { await workspace.open("B") }
  try await eventually { workspace.openingSessionId == "B" }
  backend.push(reply(id("preferences")!, #"{"recentProjects":["/p"],"archivedSessionIds":["A"]}"#))
  #expect(await archive.value)
  backend.push(reply(id("open")!, viewJSON(sessionJSON("B"))))
  await openB.value
  #expect(workspace.view?.session.sessionId == "B")
}

@MainActor @Test func aFailedToggleDoesNotStickTheChain() async throws {
  let calls = Counter()
  let (workspace, _) = await makeWorkspace { method, _, id in
    guard method == "preferences" else { return [reply(id, "null")] }
    return calls.next() == 1
      ? [failure(id, "EACCES")] : [reply(id, #"{"recentProjects":["/p"],"pinnedSessionIds":["b"]}"#)]
  }
  #expect(await workspace.togglePin("a") == false)
  #expect(await workspace.togglePin("b"))
  #expect(workspace.preferences.pinnedSessionIds == ["b"])
}

@MainActor @Test func anArchivedConversationStaysArchivedWhenAnEventShowsNewActivity() async throws {
  let list = #"{"sessions":[\#(sessionJSON("a", updatedAt: "2026-10-21T10:00:00Z")),\#(sessionJSON("b", updatedAt: "2026-10-21T09:00:00Z"))],"nextCursor":null}"#
  let (workspace, _) = await makeWorkspace(
    preferences: Preferences(recentProjects: ["/p"], archivedSessionIds: ["b"])
  ) { method, _, id in method == "sessions" ? [reply(id, list)] : [] }
  await workspace.refreshSessions()
  // A new message in the archived conversation arrives as a session event.
  let update = viewJSON(sessionJSON("b", status: "running", updatedAt: "2026-10-21T11:00:00Z", firstUserPrompt: "New"))
  workspace.apply(.session(try decodeView(update)))
  #expect(workspace.sessions.first { $0.sessionId == "b" }?.status == "running")
  #expect(workspace.preferences.archivedSessionIds == ["b"])
  #expect(workspace.isArchived("b"))
  #expect(workspace.sections.flatMap { $0.sessions.map(\.sessionId) } == ["a"])
  workspace.showArchived = true
  #expect(workspace.sections.flatMap { $0.sessions.map(\.sessionId) } == ["b"])
}
