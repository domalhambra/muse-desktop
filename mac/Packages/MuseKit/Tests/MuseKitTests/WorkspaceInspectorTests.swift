import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

/// How many `git-status` requests the backend received for `path`.
private func statusReads(_ backend: ScriptedBackend, _ path: JSONValue) -> Int {
  requests(backend).filter { $0 == ["git-status", [path]] }.count
}

/// Sends a badge read for `marker` from a task started now, and waits for it to arrive. A read an
/// earlier event started is sent before it, so a count taken afterwards has had its chance.
@MainActor
private func settle(_ workspace: Workspace, _ backend: ScriptedBackend, marker: String) async throws {
  Task { await workspace.refreshProjectGit([marker]) }
  try await eventually { statusReads(backend, .string(marker)) == 1 }
}

/// The id of the first request for `method` with these arguments.
private func firstId(_ backend: ScriptedBackend, _ method: String, _ args: JSONValue? = nil) -> Int? {
  let found = backend.messages.first { message in
    message["method"] == .string(method) && (args == nil || message["args"] == args)
  }
  guard case .number(let id)? = found?["id"] else { return nil }
  return Int(id)
}

@MainActor @Test func theInspectorFollowsTheProject() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "open" ? [reply(id, viewJSON(sessionJSON("s1", root: "/r")))] : []
  }
  #expect(workspace.inspector.project == "/p")
  workspace.selectProject("/q")
  #expect(workspace.inspector.project == "/q")
  await workspace.open("s1")
  #expect(workspace.inspector.project == "/r")
}

@MainActor @Test func projectBadgesFollowTheRecentProjects() async throws {
  let (workspace, backend) = await makeWorkspace(
    preferences: Preferences(recentProjects: ["/p", "/plain"])
  ) { method, args, id in
    switch method {
    case "sessions": return [reply(id, #"{"sessions":[],"nextCursor":null}"#)]
    case "models": return [reply(id, "[]")]
    case "git-status":
      return args.first == "/plain"
        ? [failure(id, "Choose this project using Open project first.")]
        : [reply(id, statusJSON(["a.txt"]))]
    default: return []
    }
  }
  await workspace.begin()
  #expect(workspace.projectGit.keys.sorted() == ["/p"])
  #expect(workspace.projectGit["/p"]?.changes.count == 1)
  workspace.apply(.preferences(Preferences(recentProjects: ["/p", "/plain", "/new"])))
  try await eventually { requests(backend).contains(["git-status", ["/new"]]) }
}

@MainActor @Test func anOlderBadgeReadDoesNotReplaceANewerOne() async throws {
  // The first read of /p gets no answer until the test pushes one; the recent projects change
  // meanwhile, and the newer read finishes first.
  let reads = Counter()
  let (workspace, backend) = await makeWorkspace { method, args, id in
    guard method == "git-status" else { return [] }
    if args.first == "/p", reads.next() == 1 { return [] }
    return [reply(id, statusJSON(["new"]))]
  }
  let first = Task { await workspace.refreshProjectGit() }
  try await eventually { firstId(backend, "git-status", ["/p"]) != nil }
  workspace.apply(.preferences(Preferences(recentProjects: ["/p", "/q"])))
  try await eventually { workspace.projectGit.keys.sorted() == ["/p", "/q"] }
  let id = try #require(firstId(backend, "git-status", ["/p"]))
  backend.push(reply(id, statusJSON(["old", "older"])))
  await first.value
  #expect(workspace.projectGit.keys.sorted() == ["/p", "/q"])
  #expect(workspace.projectGit["/p"]?.changes.map(\.path) == ["new"])
}

@MainActor @Test func aCancelledBadgeReadKeepsTheBadgesShown() async throws {
  let reads = Counter()
  let (workspace, backend) = await makeWorkspace { method, _, id in
    guard method == "git-status" else { return [] }
    return reads.next() == 1 ? [reply(id, statusJSON(["a.txt"]))] : []  // later reads never answer
  }
  await workspace.refreshProjectGit()
  let stuck = Task { await workspace.refreshProjectGit() }
  try await eventually { backend.messages.filter { $0["method"] == "git-status" }.count == 2 }
  stuck.cancel()
  await stuck.value
  #expect(workspace.projectGit["/p"]?.changes.count == 1)
  let stuckOne = Task { await workspace.refreshProjectGit(["/p"]) }
  try await eventually { backend.messages.filter { $0["method"] == "git-status" }.count == 3 }
  stuckOne.cancel()
  await stuckOne.value
  #expect(workspace.projectGit["/p"]?.changes.count == 1)
}

@MainActor @Test func aTurnThatEndsReadsItsProjectsBadgeAgain() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "open": [reply(id, viewJSON(sessionJSON("s1", status: "running")))]
    case "git-status": [reply(id, statusJSON([]))]
    default: []
    }
  }
  await workspace.open("s1")
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s1", status: "idle")))))
  try await eventually { requests(backend).contains(["git-status", ["/p"]]) }
  try await eventually { workspace.projectGit["/p"] != nil }
}

@MainActor @Test func onlyATurnThatEndsReadsTheBadge() async throws {
  let worktree = "/p/.muse/worktrees/w1"
  let (workspace, backend) = await makeWorkspace { method, args, id in
    switch method {
    case "open":
      args.first == "w1"
        ? [reply(id, viewJSON(sessionJSON("w1", root: worktree, status: "running")))]
        : [reply(id, viewJSON(sessionJSON("s1", status: "running")))]
    case "git-status": [reply(id, statusJSON([]))]
    default: []
    }
  }
  await workspace.open("s1")
  // running to running: a streamed update mid-turn.
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s1", status: "running")))))
  try await settle(workspace, backend, marker: "/m1")
  #expect(statusReads(backend, "/p") == 0)
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s1", status: "idle")))))
  try await eventually { statusReads(backend, "/p") == 1 }
  // idle to idle: a rename or a history update after the turn.
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("s1", status: "idle")))))
  try await settle(workspace, backend, marker: "/m2")
  #expect(statusReads(backend, "/p") == 1)
  // A worktree conversation's folder is the current project, which the sidebar badges.
  await workspace.open("w1")
  #expect(workspace.project == worktree)
  // Opening it reads its badge once; the turn's end reads it again.
  try await eventually { statusReads(backend, .string(worktree)) == 1 }
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("w1", root: worktree, status: "idle")))))
  try await eventually { statusReads(backend, .string(worktree)) == 2 }
  try await eventually { workspace.projectGit[worktree] != nil }
}

@MainActor @Test func aTurnThatEndsOutsideTheBadgedProjectsReadsNoBadge() async throws {
  // The conversation opened in /p/.muse/worktrees/w1 (the current project); its turn ends with a
  // folder that is neither a recent project nor the current one.
  let opened = "/p/.muse/worktrees/w1"
  let root = "/elsewhere"
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "open": [reply(id, viewJSON(sessionJSON("w1", root: opened, status: "running")))]
    case "git-status": [reply(id, statusJSON([]))]
    default: []
    }
  }
  await workspace.open("w1")
  workspace.apply(.session(try decodeView(viewJSON(sessionJSON("w1", root: root, status: "idle")))))
  try await settle(workspace, backend, marker: "/m1")
  #expect(statusReads(backend, .string(root)) == 0)
  #expect(workspace.projectGit[root] == nil)
}

@MainActor @Test func aFullBadgeReadAlsoReadsTheCurrentProject() async throws {
  // A worktree conversation's folder is not a recent project, but the sidebar shows its badge.
  let root = "/p/.muse/worktrees/w1"
  let (workspace, backend) = await makeWorkspace { method, args, id in
    switch method {
    case "open": [reply(id, viewJSON(sessionJSON("w1", root: root)))]
    case "git-status": [reply(id, statusJSON(args.first == .string(root) ? ["w.txt"] : []))]
    default: []
    }
  }
  await workspace.open("w1")
  #expect(workspace.project == root)
  // Opening it reads its badge once.
  try await eventually { workspace.projectGit[root] != nil }
  await workspace.refreshProjectGit()
  #expect(statusReads(backend, .string(root)) == 2)
  #expect(workspace.projectGit.keys.sorted() == ["/p", root])
  #expect(workspace.projectGit[root]?.changes.map(\.path) == ["w.txt"])
  // A later full read keeps it.
  await workspace.refreshProjectGit()
  #expect(workspace.projectGit.keys.sorted() == ["/p", root])
  // The current project is read once, not twice, when it is also a recent project.
  workspace.selectProject("/p")
  try await eventually { statusReads(backend, "/p") == 3 }
  await workspace.refreshProjectGit()
  #expect(statusReads(backend, "/p") == 4)
}

@MainActor @Test func recentProjectsSavedDuringBeginAreReadOnceByBegin() async throws {
  // sessions gets no answer until the test pushes one; history loading saves the recent projects.
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "sessions": []
    case "models": [reply(id, "[]")]
    case "git-status": [reply(id, statusJSON([]))]
    default: [reply(id, "[]")]
    }
  }
  let beginning = Task { await workspace.begin() }
  try await eventually { backend.messages.contains { $0["method"] == "sessions" } }
  workspace.apply(.preferences(Preferences(recentProjects: ["/p", "/new"])))
  try await settle(workspace, backend, marker: "/m1")
  #expect(statusReads(backend, "/p") == 0)
  #expect(statusReads(backend, "/new") == 0)
  let id = try #require(firstId(backend, "sessions"))
  backend.push(reply(id, #"{"sessions":[],"nextCursor":null}"#))
  await beginning.value
  #expect(workspace.projectGit.keys.sorted() == ["/new", "/p"])
  try await settle(workspace, backend, marker: "/m2")
  #expect(statusReads(backend, "/p") == 1)
  #expect(statusReads(backend, "/new") == 1)
  // After begin, a change reads them again.
  workspace.apply(.preferences(Preferences(recentProjects: ["/p", "/new", "/later"])))
  try await eventually { statusReads(backend, "/later") == 1 }
}

@MainActor @Test func recentProjectsSavedDuringBeginsFinalReadAreReadAgain() async throws {
  // begin's read of /p gets no answer until the test pushes one; the recent projects change meanwhile.
  let reads = Counter()
  let (workspace, backend) = await makeWorkspace { method, args, id in
    switch method {
    case "sessions": return [reply(id, #"{"sessions":[],"nextCursor":null}"#)]
    case "models": return [reply(id, "[]")]
    case "git-status":
      if args.first == "/p", reads.next() == 1 { return [] }
      return [reply(id, statusJSON([]))]
    default: return [reply(id, "[]")]
    }
  }
  let beginning = Task { await workspace.begin() }
  try await eventually { statusReads(backend, "/p") == 1 }
  workspace.apply(.preferences(Preferences(recentProjects: ["/p", "/q"])))
  try await eventually { statusReads(backend, "/q") == 1 }
  try await eventually { workspace.projectGit.keys.sorted() == ["/p", "/q"] }
  let id = try #require(firstId(backend, "git-status", ["/p"]))
  backend.push(reply(id, statusJSON(["old"])))
  await beginning.value
  // The newer read wins by its sequence.
  #expect(workspace.projectGit.keys.sorted() == ["/p", "/q"])
  #expect(workspace.projectGit["/p"]?.changes.isEmpty == true)
}

@MainActor @Test func aSendDuringHistoryLoadIsNotHiddenByTheReopen() async throws {
  // Neither sessions nor create is answered until the test pushes the replies.
  let (workspace, backend) = await makeWorkspace(reopen: "s7") { method, _, id in
    switch method {
    case "sessions", "create": []
    case "models": [reply(id, "[]")]
    case "open": [reply(id, viewJSON(sessionJSON("s7")))]
    default: [reply(id, "null")]
    }
  }
  let beginning = Task { await workspace.begin() }
  try await eventually { backend.messages.contains { $0["method"] == "sessions" } }
  workspace.draft = "hi"
  let sending = Task { await workspace.send() }
  try await eventually { backend.messages.contains { $0["method"] == "create" } }
  let sessionsId = try #require(firstId(backend, "sessions"))
  backend.push(reply(sessionsId, #"{"sessions":[],"nextCursor":null}"#))
  await beginning.value
  let createId = try #require(firstId(backend, "create"))
  backend.push(reply(createId, viewJSON(sessionJSON("s1"))))
  #expect(await sending.value == .sent)
  #expect(workspace.view?.session.sessionId == "s1")
  #expect(!requests(backend).contains(["open", ["s7"]]))
}

@MainActor @Test func anInspectorRefreshUpdatesItsBadge() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "worktrees": [reply(id, "[]")]
    case "git-status": [reply(id, statusJSON(["x", "y"]))]
    default: []
    }
  }
  await workspace.inspector.refresh()
  #expect(workspace.projectGit["/p"]?.changes.count == 2)
}

@MainActor @Test func inspectorFailuresShowInTheWindowAlert() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "git-diff": [reply(id, #""""#)]
    case "git-stage-file": [failure(id, "stage failed")]
    default: [reply(id, method == "git-status" ? statusJSON(["a.txt"]) : "[]")]
    }
  }
  await workspace.inspector.select("a.txt")
  await workspace.inspector.stage()
  #expect(workspace.errorMessage == "stage failed")
}

@MainActor @Test func aWorktreeConversationFollowsItsWorktree() async throws {
  let (workspace, backend) = await makeWorkspace(
    status: ConnectionStatus(state: "ready", version: "1.4.11", experimental: true)
  ) { method, _, id in
    switch method {
    case "create": [reply(id, viewJSON(sessionJSON("w1", root: "/p/.muse/worktrees/w1")))]
    default: [reply(id, "null")]
    }
  }
  #expect(workspace.canStartInWorktree)
  workspace.startInWorktree = true
  workspace.draft = "Try it on a branch"
  #expect(await workspace.send() == .sent)
  #expect(requests(backend).contains(["create", ["/p", nil, ["worktree": true]]]))
  #expect(!workspace.startInWorktree)
  #expect(workspace.project == "/p/.muse/worktrees/w1")
  #expect(workspace.inspector.project == "/p/.muse/worktrees/w1")
  #expect(!workspace.canStartInWorktree)
}

@MainActor @Test func aWorktreeSendAfterOpeningAnotherConversationKeepsItsProject() async throws {
  // create gets no answer until the test pushes one; the person opens s2 meanwhile.
  let (workspace, backend) = await makeWorkspace(
    status: ConnectionStatus(state: "ready", version: "1.4.11", experimental: true)
  ) { method, _, id in
    switch method {
    case "create": []
    case "open": [reply(id, viewJSON(sessionJSON("s2", root: "/q")))]
    default: [reply(id, "null")]
    }
  }
  workspace.startInWorktree = true
  workspace.draft = "Try it on a branch"
  let sending = Task { await workspace.send() }
  try await eventually { backend.messages.contains { $0["method"] == "create" } }
  await workspace.open("s2")
  let id = try #require(firstId(backend, "create"))
  backend.push(reply(id, viewJSON(sessionJSON("w1", root: "/p/.muse/worktrees/w1"))))
  #expect(await sending.value == .sent)
  #expect(!workspace.startInWorktree)
  #expect(workspace.view?.session.sessionId == "s2")
  #expect(workspace.project == "/q")
  #expect(workspace.inspector.project == "/q")
}

@MainActor @Test func withoutExperimentalMethodsTheWorktreeOptionIsIgnored() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "create" ? [reply(id, viewJSON(sessionJSON("s1")))] : [reply(id, "null")]
  }
  #expect(!workspace.canStartInWorktree)
  workspace.startInWorktree = true
  workspace.draft = "hi"
  _ = await workspace.send()
  #expect(requests(backend).contains(["create", ["/p"]]))
}

@MainActor @Test func askMuseAddsElectronsSentences() async throws {
  let (workspace, _) = await makeWorkspace()
  workspace.askAboutChanges("src/a.swift")
  #expect(workspace.draft == "Please review the changes in @src/a.swift\n")
  workspace.askAboutFile("docs/the \"plan\".md")
  #expect(
    workspace.draft
      == "Please review the changes in @src/a.swift\n\nPlease look at the project file: \"docs/the \\\"plan\\\".md\"\n"
  )
  #expect(workspace.composerFocusRequest == 2)
}

@MainActor @Test func theConversationOpenBeforeARestartReopens() async throws {
  let (workspace, backend) = await makeWorkspace(reopen: "s7") { method, _, id in
    switch method {
    case "sessions": [reply(id, #"{"sessions":[],"nextCursor":null}"#)]
    case "models": [reply(id, "[]")]
    case "open": [reply(id, viewJSON(sessionJSON("s7")))]
    default: [reply(id, "[]")]
    }
  }
  await workspace.begin()
  #expect(workspace.view?.session.sessionId == "s7")
  // Once only: a later `ready` does not open it again over another conversation.
  workspace.startNew()
  await workspace.begin()
  #expect(workspace.view == nil)
  #expect(requests(backend).filter { $0.first == "open" }.count == 1)
}

@MainActor @Test func aReopenNotYetDoneIsPendingUntilBeginOpensIt() async throws {
  let (workspace, _) = await makeWorkspace(reopen: "s7") { method, _, id in
    switch method {
    case "sessions": [reply(id, #"{"sessions":[],"nextCursor":null}"#)]
    case "models": [reply(id, "[]")]
    case "open": [reply(id, viewJSON(sessionJSON("s7")))]
    default: [reply(id, "[]")]
    }
  }
  #expect(workspace.pendingReopen == "s7")
  await workspace.begin()
  #expect(workspace.view?.session.sessionId == "s7")
  #expect(workspace.pendingReopen == nil)
}

@MainActor @Test func aConversationOpenedBeforeHistoryLoadsIsNotReplacedByTheReopen() async throws {
  // sessions gets no answer until the test pushes one; the person opens s2 meanwhile.
  let (workspace, backend) = await makeWorkspace(reopen: "s7") { method, args, id in
    switch method {
    case "sessions": []
    case "models": [reply(id, "[]")]
    case "open": [reply(id, viewJSON(sessionJSON(args.first == "s2" ? "s2" : "s7")))]
    default: [reply(id, "[]")]
    }
  }
  let beginning = Task { await workspace.begin() }
  try await eventually { backend.messages.contains { $0["method"] == "sessions" } }
  await workspace.open("s2")
  let id = try #require(firstId(backend, "sessions"))
  backend.push(reply(id, #"{"sessions":[],"nextCursor":null}"#))
  await beginning.value
  #expect(workspace.view?.session.sessionId == "s2")
  #expect(!requests(backend).contains(["open", ["s7"]]))
}

@MainActor @Test func aConversationOpeningBeforeHistoryLoadsIsNotReplacedByTheReopen() async throws {
  // Neither sessions nor the open of s2 is answered until the test pushes the replies.
  let (workspace, backend) = await makeWorkspace(reopen: "s7") { method, args, id in
    switch method {
    case "sessions": []
    case "models": [reply(id, "[]")]
    case "open": args.first == "s2" ? [] : [reply(id, viewJSON(sessionJSON("s7")))]
    default: [reply(id, "[]")]
    }
  }
  let beginning = Task { await workspace.begin() }
  try await eventually { backend.messages.contains { $0["method"] == "sessions" } }
  let opening = Task { await workspace.open("s2") }
  try await eventually { workspace.openingSessionId == "s2" }
  let sessionsId = try #require(firstId(backend, "sessions"))
  backend.push(reply(sessionsId, #"{"sessions":[],"nextCursor":null}"#))
  await beginning.value
  try await eventually { backend.messages.contains { $0["method"] == "open" } }
  let openId = try #require(firstId(backend, "open", ["s2"]))
  backend.push(reply(openId, viewJSON(sessionJSON("s2"))))
  await opening.value
  #expect(workspace.view?.session.sessionId == "s2")
  #expect(!requests(backend).contains(["open", ["s7"]]))
}

@MainActor @Test func aWorktreeConversationReadsItsOwnBadge() async throws {
  // Opening a worktree conversation reads its folder's badge without an inspector refresh or a
  // full read. The worktree's read waits until the test pushes its reply.
  let worktree = "/p/.muse/worktrees/x"
  let (workspace, backend) = await makeWorkspace { method, args, id in
    switch method {
    case "open": return [reply(id, viewJSON(sessionJSON("w1", root: worktree)))]
    case "git-status": return args.first == .string(worktree) ? [] : [reply(id, statusJSON([]))]
    default: return []
    }
  }
  await workspace.refreshProjectGit()
  #expect(workspace.projectBadge?.branch == "main")
  await workspace.open("w1")
  try await eventually { statusReads(backend, .string(worktree)) == 1 }
  // Until its own read lands the badge is empty, not the parent's "main · Clean".
  #expect(workspace.projectBadge == nil)
  let id = try #require(firstId(backend, "git-status", [.string(worktree)]))
  backend.push(reply(id, statusJSON(["w.txt"], branch: "muse/x")))
  try await eventually { workspace.projectBadge?.branch == "muse/x" }
  // All projects has no badge, and reads none.
  workspace.selectProject("")
  #expect(workspace.projectBadge == nil)
  try await settle(workspace, backend, marker: "/m1")
  #expect(statusReads(backend, "") == 0)
}

@MainActor @Test func anOlderFullBadgeReadKeepsTheNewProjectsBadge() async throws {
  // The full read's /p gets no answer until the test pushes one; a worktree conversation opens
  // meanwhile and its own read lands first.
  let worktree = "/p/.muse/worktrees/x"
  let reads = Counter()
  let (workspace, backend) = await makeWorkspace { method, args, id in
    switch method {
    case "open": return [reply(id, viewJSON(sessionJSON("w1", root: worktree)))]
    case "git-status":
      if args.first == "/p", reads.next() == 1 { return [] }
      return [reply(id, statusJSON([], branch: args.first == .string(worktree) ? "muse/x" : "main"))]
    default: return []
    }
  }
  let full = Task { await workspace.refreshProjectGit() }
  try await eventually { firstId(backend, "git-status", ["/p"]) != nil }
  await workspace.open("w1")
  try await eventually { workspace.projectBadge?.branch == "muse/x" }
  let id = try #require(firstId(backend, "git-status", ["/p"]))
  backend.push(reply(id, statusJSON([])))
  await full.value
  #expect(workspace.projectGit["/p"] != nil)
  #expect(workspace.projectBadge?.branch == "muse/x")
}
