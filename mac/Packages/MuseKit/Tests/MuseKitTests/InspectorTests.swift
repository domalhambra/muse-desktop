import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

/// An Inspector over a scripted backend, as `makeWorkspace` builds a Workspace.
@MainActor
func makeInspector(
  project: String = "/p",
  script: @escaping @Sendable (String, [JSONValue], Int) -> [String] = { _, _, _ in [] }
) async -> (Inspector, ScriptedBackend) {
  let backend = ScriptedBackend { message in
    guard case .string(let method)? = message["method"], case .number(let id)? = message["id"],
      case .array(let args)? = message["args"]
    else { return [] }
    return script(method, args, Int(id))
  }
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  return (Inspector(client: client, project: project), backend)
}

func statusJSON(_ paths: [String], branch: String = "main") -> String {
  let changes = paths.map { #"{"path":"\#($0)","status":"M","staged":false}"# }.joined(separator: ",")
  return #"{"branch":"\#(branch)","isRepository":true,"changes":[\#(changes)]}"#
}

let worktreesJSON =
  #"[{"path":"/p","branch":"main","isMain":true,"sessionIds":[]},{"path":"/p/.muse/worktrees/w1","branch":"muse/w1","isMain":false,"sessionIds":[]}]"#

@MainActor @Test func refreshReadsWorktreesAndStatusAndPassesTheStatusOn() async throws {
  let (inspector, backend) = await makeInspector { method, _, id in
    switch method {
    case "worktrees": [reply(id, worktreesJSON)]
    case "git-status": [reply(id, statusJSON(["a.txt"]))]
    default: []
    }
  }
  var read: [String] = []
  inspector.statusRead = { path, status in read.append("\(path):\(status.changes.count)") }
  await inspector.refresh()
  #expect(inspector.git?.branch == "main")
  #expect(inspector.museWorktrees.map(\.path) == ["/p/.muse/worktrees/w1"])
  #expect(inspector.mainBranch == "main")
  #expect(read == ["/p:1"])
  #expect(!inspector.loading)
  #expect(requests(backend) == [["worktrees", ["/p"]], ["git-status", ["/p"]]])
}

@MainActor @Test func aFailedWorktreeListGivesNoneAndAFailedStatusShows() async throws {
  let (inspector, _) = await makeInspector { method, _, id in
    [failure(id, method == "worktrees" ? "untrusted" : "git failed")]
  }
  await inspector.refresh()
  #expect(inspector.worktrees.isEmpty)
  #expect(inspector.error == "git failed")
  #expect(inspector.mainBranch == "the main checkout")
}

@MainActor @Test func aCancelledRefreshKeepsTheWorktreesShown() async throws {
  let lists = Counter()
  let (inspector, backend) = await makeInspector { method, _, id in
    switch method {
    case "worktrees": lists.next() == 1 ? [reply(id, worktreesJSON)] : []  // the second never answers
    case "git-status": [reply(id, statusJSON([]))]
    default: []
    }
  }
  await inspector.refresh()
  let stuck = Task { await inspector.refresh() }
  try await eventually { backend.messages.filter { $0["method"] == "worktrees" }.count == 2 }
  stuck.cancel()
  await stuck.value
  #expect(inspector.museWorktrees.map(\.path) == ["/p/.muse/worktrees/w1"])
  #expect(!inspector.loading)
}

@MainActor @Test func aRefreshKeepsTheOpenDiffWhileItsFileStillChanges() async throws {
  let changed = Counter()
  let (inspector, backend) = await makeInspector { method, _, id in
    switch method {
    case "git-status": return [reply(id, statusJSON(changed.value == 0 ? ["a.txt"] : []))]
    case "git-diff": return [reply(id, #""Working changes\n@@ -1 +1 @@\n-a\n+b""#)]
    default: return [reply(id, "[]")]
    }
  }
  await inspector.refresh()
  await inspector.select("a.txt")
  guard case .loaded(let rows) = inspector.diff else { Issue.record("No diff"); return }
  #expect(rows.contains { $0.hunkIndex == 0 })
  await inspector.refresh()
  #expect(inspector.selected == "a.txt")
  #expect(requests(backend).filter { $0.first == "git-diff" }.count == 2)
  changed.next()
  await inspector.refresh()
  #expect(inspector.selected == nil)
  #expect(inspector.diff == .idle)
}

@MainActor @Test func aDiffForAnEarlierSelectionIsDropped() async throws {
  let (inspector, backend) = await makeInspector { method, args, id in
    guard method == "git-diff", args.last == "b.txt" else { return [] }
    return [reply(id, #""for b""#)]
  }
  let first = Task { await inspector.select("a.txt") }
  try await eventually { backend.messages.contains { $0["method"] == "git-diff" } }
  await inspector.select("b.txt")
  guard case .number(let late)? = backend.messages.first(where: { $0["method"] == "git-diff" })?["id"] else {
    Issue.record("No first diff request")
    return
  }
  backend.push(reply(Int(late), #""for a""#))
  await first.value
  #expect(inspector.selected == "b.txt")
  #expect(inspector.diff == .loaded(DiffLine.parse("for b")))
}

@MainActor @Test func aDiffThatFailsShowsItsMessage() async throws {
  let (inspector, _) = await makeInspector { method, _, id in
    method == "git-diff" ? [failure(id, "This file no longer has changes. Refresh the changes panel.")] : []
  }
  await inspector.select("a.txt")
  #expect(inspector.diff == .failed("This file no longer has changes. Refresh the changes panel."))
}

@MainActor @Test func reviewActionsCallTheBackendThenRefresh() async throws {
  let (inspector, backend) = await makeInspector { method, _, id in
    switch method {
    case "git-status": [reply(id, statusJSON(["a.txt"]))]
    case "git-diff": [reply(id, #""""#)]
    case "worktrees": [reply(id, "[]")]
    default: [reply(id, "null")]
    }
  }
  await inspector.select("a.txt")
  await inspector.revertHunk(1)
  await inspector.stage()
  await inspector.revertFile()
  let names: [JSONValue] = ["git-revert-hunk", "git-stage-file", "git-revert-file"]
  let calls = requests(backend).filter { $0.first.map(names.contains) ?? false }
  #expect(calls == [
    ["git-revert-hunk", ["/p", "a.txt", 1]],
    ["git-stage-file", ["/p", "a.txt"]],
    ["git-revert-file", ["/p", "a.txt"]],
  ])
  // Each action is followed by a refresh.
  #expect(requests(backend).filter { $0.first == "git-status" }.count == 3)
  #expect(!inspector.busy)
}

@MainActor @Test func actionsRunOneAtATimeAndReportFailures() async throws {
  let (inspector, backend) = await makeInspector { method, _, id in
    switch method {
    case "git-stage-file": []  // never answers, so the first action stays busy
    case "git-revert-file": [failure(id, "This file has no changes to revert.")]
    case "git-diff": [reply(id, #""""#)]
    default: [reply(id, method == "git-status" ? statusJSON(["a.txt"]) : "[]")]
    }
  }
  var reported: [String] = []
  inspector.reportError = { reported.append($0) }
  await inspector.select("a.txt")
  let staging = Task { await inspector.stage() }
  try await eventually { inspector.busy }
  await inspector.revertFile()
  #expect(!backend.messages.contains { $0["method"] == "git-revert-file" })
  staging.cancel()
  await staging.value
  // A cancelled action skips its refresh.
  #expect(!backend.messages.contains { $0["method"] == "git-status" })
  await inspector.revertFile()
  #expect(reported == ["This file has no changes to revert."])
}

@MainActor @Test func mergeReportsAFailedOutputAndShowsASuccessfulOne() async throws {
  let merges = Counter()
  let (inspector, backend) = await makeInspector { method, _, id in
    switch method {
    case "worktree-merge":
      return merges.next() == 1
        ? [reply(id, #"{"ok":false,"output":"The worktree has uncommitted changes."}"#)]
        : [reply(id, #"{"ok":true,"output":"Merged muse/w1."}"#)]
    case "worktrees": return [reply(id, worktreesJSON)]
    case "git-status": return [reply(id, statusJSON([]))]
    default: return [reply(id, "null")]
    }
  }
  var reported: [String] = []
  inspector.reportError = { reported.append($0) }
  await inspector.refresh()
  let entry = try #require(inspector.museWorktrees.first)
  await inspector.merge(entry)
  #expect(reported == ["The worktree has uncommitted changes."])
  #expect(inspector.notice == nil)
  await inspector.merge(entry)
  #expect(inspector.notice == "Merged muse/w1.")
  await inspector.remove(entry)
  #expect(inspector.notice == nil)
  #expect(requests(backend).contains(["worktree-remove", ["/p", "/p/.muse/worktrees/w1"]]))
}

@MainActor @Test func showingAnotherProjectResetsAndDropsLateReplies() async throws {
  let (inspector, backend) = await makeInspector { method, args, id in
    // The first project's worktree list answers late, below. Everything else answers at once.
    if args.first == "/p", method == "worktrees" { return [] }
    if method == "git-status" { return [reply(id, statusJSON([], branch: args.first == "/q" ? "dev" : "main"))] }
    return [reply(id, "[]")]
  }
  inspector.tab = .files
  let old = Task { await inspector.refresh() }
  try await eventually { backend.messages.contains { $0["method"] == "worktrees" } }
  inspector.show(project: "/q")
  #expect(inspector.project == "/q")
  #expect(inspector.git == nil)
  #expect(inspector.tab == .changes)
  guard case .number(let late)? = backend.messages.first(where: { $0["method"] == "worktrees" })?["id"] else {
    Issue.record("No first worktrees request")
    return
  }
  backend.push(reply(Int(late), worktreesJSON))
  await old.value
  #expect(inspector.worktrees.isEmpty)
  #expect(inspector.git == nil)
  #expect(!inspector.loading)
  #expect(!requests(backend).contains(["git-status", ["/p"]]))
  await inspector.refresh()
  #expect(inspector.git?.branch == "dev")
}

@MainActor @Test func anActionAcrossAProjectChangeIsDropped() async throws {
  let (inspector, backend) = await makeInspector { method, args, id in
    switch method {
    case "git-stage-file": return []  // answered late, below
    case "git-diff": return [reply(id, #""""#)]
    case "git-status": return [reply(id, statusJSON([]))]
    default: return [reply(id, "[]")]
    }
  }
  var reported: [String] = []
  inspector.reportError = { reported.append($0) }
  await inspector.select("a.txt")
  let staging = Task { await inspector.stage() }
  try await eventually { backend.messages.contains { $0["method"] == "git-stage-file" } }
  inspector.show(project: "/q")
  #expect(!inspector.busy)
  guard case .number(let late)? = backend.messages.first(where: { $0["method"] == "git-stage-file" })?["id"] else {
    Issue.record("No stage request")
    return
  }
  backend.push(failure(Int(late), "This file has no changes to stage."))
  await staging.value
  #expect(reported.isEmpty)
  #expect(!inspector.busy)
  // Neither project is refreshed for an action that belongs to the one the person left.
  #expect(!backend.messages.contains { $0["method"] == "git-status" })
}

@MainActor @Test func aDiffAcrossAProjectChangeIsDropped() async throws {
  let (inspector, backend) = await makeInspector()
  let selecting = Task { await inspector.select("a.txt") }
  try await eventually { backend.messages.contains { $0["method"] == "git-diff" } }
  inspector.show(project: "/q")
  guard case .number(let late)? = backend.messages.first(where: { $0["method"] == "git-diff" })?["id"] else {
    Issue.record("No diff request")
    return
  }
  backend.push(reply(Int(late), #""for a""#))
  await selecting.value
  #expect(inspector.selected == nil)
  #expect(inspector.diff == .idle)
}

@MainActor @Test func filesAndAPreviewAcrossAProjectChangeAreDropped() async throws {
  let (inspector, backend) = await makeInspector()  // the replies come late, below
  let opening = Task { await inspector.open(directory: "src") }
  let previewing = Task { await inspector.preview("README.md") }
  try await eventually {
    backend.messages.contains { $0["method"] == "files" } && backend.messages.contains { $0["method"] == "read-file" }
  }
  inspector.show(project: "/q")
  guard case .number(let files)? = backend.messages.first(where: { $0["method"] == "files" })?["id"],
    case .number(let read)? = backend.messages.first(where: { $0["method"] == "read-file" })?["id"]
  else {
    Issue.record("No files or read-file request")
    return
  }
  backend.push(reply(Int(files), #"[{"name":"App.swift","path":"src/App.swift","directory":false}]"#))
  backend.push(reply(Int(read), #""late""#))
  await opening.value
  await previewing.value
  #expect(inspector.files.isEmpty)
  #expect(inspector.directory == "")
  #expect(!inspector.filesLoading)
  #expect(inspector.previewPath == nil)
  #expect(inspector.preview == .idle)
}

@MainActor @Test func aCancelledReadShowsNoMessage() async throws {
  let (inspector, backend) = await makeInspector()  // nothing answers
  let reads: [Task<Void, Never>] = [
    Task { await inspector.select("a.txt") },
    Task { await inspector.open(directory: "src") },
    Task { await inspector.preview("README.md") },
  ]
  try await eventually { backend.messages.count == 3 }
  for read in reads { read.cancel() }
  for read in reads { await read.value }
  if case .failed(let message) = inspector.diff { Issue.record("The diff shows \(message)") }
  if case .failed(let message) = inspector.preview { Issue.record("The preview shows \(message)") }
  #expect(inspector.filesError == nil)
  #expect(!inspector.filesLoading)
}

@MainActor @Test func aMergeThatFailsSilentlySaysSo() async throws {
  let (inspector, _) = await makeInspector { method, _, id in
    switch method {
    case "worktree-merge": [reply(id, #"{"ok":false,"output":""}"#)]
    case "git-status": [reply(id, statusJSON([]))]
    default: [reply(id, "[]")]
    }
  }
  var reported: [String] = []
  inspector.reportError = { reported.append($0) }
  await inspector.merge(WorktreeEntry(path: "/p/.muse/worktrees/w1", branch: "muse/w1", isMain: false))
  #expect(reported == ["The merge did not finish."])
}

@MainActor @Test func filesOpenFoldersFilterAndPreview() async throws {
  let (inspector, backend) = await makeInspector { method, args, id in
    if method == "files", args.last == "" {
      return [reply(id, #"[{"name":"src","path":"src","directory":true},{"name":"README.md","path":"README.md","directory":false}]"#)]
    }
    if method == "files", args.last == "src" {
      return [reply(id, #"[{"name":"App.swift","path":"src/App.swift","directory":false}]"#)]
    }
    return method == "read-file" ? [reply(id, #""let a = 1\nlet b = 2""#)] : []
  }
  await inspector.open(directory: "")
  #expect(inspector.files.map(\.name) == ["src", "README.md"])
  inspector.query = "READ"
  #expect(inspector.visibleFiles.map(\.name) == ["README.md"])
  await inspector.choose(inspector.files[0])
  #expect(inspector.directory == "src")
  #expect(inspector.query == "")
  await inspector.choose(inspector.files[0])
  #expect(inspector.previewPath == "src/App.swift")
  #expect(inspector.preview == .loaded("let a = 1\nlet b = 2"))
  await inspector.openParent()
  #expect(inspector.directory == "")
  #expect(requests(backend).filter { $0.first == "files" } == [["files", ["/p", ""]], ["files", ["/p", "src"]], ["files", ["/p", ""]]])
}
