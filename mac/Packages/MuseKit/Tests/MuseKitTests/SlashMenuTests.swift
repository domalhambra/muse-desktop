import Foundation
import MuseBackend
import MuseBackendTesting
import Synchronization
import Testing
@testable import MuseKit

private let skills = [
  SkillRow(selector: "create-skill", description: "Make a skill"),
  SkillRow(selector: "acme:deploy", description: "Deploy"),
  SkillRow(selector: "help", description: "Shadowed"),
]

@Test func theMenuListsCommandsThenSkills() {
  let rows = SlashMenu.rows(for: "/", skills: skills)
  #expect(rows.prefix(ComposerCommand.allCases.count).map(\.name) == ComposerCommand.allCases.map(\.name))
  #expect(rows.suffix(2).map(\.name) == ["create-skill", "acme:deploy"])
  #expect(rows.count == ComposerCommand.allCases.count + 2)
}

@Test func theMenuFiltersByTheTypedText() {
  #expect(SlashMenu.rows(for: "/cr", skills: skills).map(\.name) == ["create-skill"])
  #expect(SlashMenu.rows(for: "/acme:", skills: skills).map(\.name) == ["acme:deploy"])
  #expect(SlashMenu.rows(for: "/create-skill now", skills: skills).isEmpty)
  #expect(SlashMenu.rows(for: "hello", skills: skills).isEmpty)
}

@Test func aSkillInvocationNeedsAKnownSelector() {
  #expect(
    SlashMenu.invocation("/acme:deploy now", skills: skills)
      == SkillInvocation(selector: "acme:deploy", arguments: "now"))
  #expect(
    SlashMenu.invocation("  /create-skill\n", skills: skills)
      == SkillInvocation(selector: "create-skill", arguments: ""))
  #expect(SlashMenu.invocation("/unknown", skills: skills) == nil)
  #expect(SlashMenu.invocation("/help", skills: skills) == nil)
}

@Test func theKeysMatchTheCommandMenu() {
  #expect(SlashMenu.keyAction(.down, draft: "/cr", index: 0, skills: skills) == .select(0))
  #expect(SlashMenu.keyAction(.tab, draft: "/cr", index: 0, skills: skills) == .setDraft("/create-skill "))
  #expect(SlashMenu.keyAction(.enter, draft: "/cr", index: 0, skills: skills) == .setDraft("/create-skill "))
  #expect(SlashMenu.keyAction(.enter, draft: "/create-skill", index: 0, skills: skills) == .submit)
  #expect(SlashMenu.keyAction(.escape, draft: "/cr", index: 0, skills: skills) == .setDraft("/cr "))
  #expect(SlashMenu.keyAction(.tab, draft: "hello", index: 0, skills: skills) == .pass)
}

@MainActor @Test func aSkillNeedsAConversation() async throws {
  let (workspace, backend) = await makeWorkspace { _, _, id in [reply(id, "null")] }
  await workspace.runSkill(SkillInvocation(selector: "x", arguments: ""))
  #expect(workspace.errorMessage == Workspace.needsConversation)
  #expect(requests(backend).filter { $0.first == .string("send-skill") }.isEmpty)
}

private let skillsJSON = #"[{"selector":"create-skill","displayName":"create-skill","description":"Make a skill"}]"#

private final class RequestId: Sendable {
  private let value = Mutex<Int?>(nil)
  func set(_ id: Int) { value.withLock { $0 = id } }
  var current: Int? { value.withLock { $0 } }
}

/// Answers `open` with the session named in the request, `skill-rows` with `rows` (never, when
/// nil), `attachments` with one chip, and the rest with null.
private func skillScript(
  rows: String?, failing: Bool = false, rowsId: RequestId? = nil
) -> @Sendable (String, [JSONValue], Int) -> [String] {
  { method, args, id in
    switch method {
    case "open":
      guard case .string(let target)? = args.first else { return [] }
      return [reply(id, viewJSON(sessionJSON(target)))]
    case "skill-rows":
      rowsId?.set(id)
      if failing { return [failure(id, "no skills today")] }
      return rows.map { [reply(id, $0)] } ?? []
    case "attachments": return [reply(id, #"[{"id":"a1","name":"a.txt","kind":"text","size":3}]"#)]
    default: return [reply(id, "null")]
    }
  }
}

@MainActor @Test func theSkillRowsLoadForTheOpenConversation() async throws {
  let (workspace, backend) = await makeWorkspace(script: skillScript(rows: skillsJSON))
  await workspace.loadSkills()
  #expect(workspace.skillRows.isEmpty)
  await workspace.open("s1")
  await workspace.loadSkills()
  #expect(workspace.skillRows.map(\.selector) == ["create-skill"])
  #expect(requests(backend).last == [.string("skill-rows"), .array([.string("s1")])])
  await workspace.open("s2")
  #expect(workspace.skillRows.isEmpty)
  await workspace.loadSkills()
  workspace.startNew()
  #expect(workspace.skillRows.isEmpty)
}

@MainActor @Test func aFailedSkillReadShowsNoRowsAndNoError() async throws {
  let (workspace, _) = await makeWorkspace(script: skillScript(rows: nil, failing: true))
  await workspace.open("s1")
  await workspace.loadSkills()
  #expect(workspace.skillRows.isEmpty)
  #expect(workspace.errorMessage == nil)
  // The commands still show.
  #expect(SlashMenu.rows(for: "/", skills: workspace.skillRows).count == ComposerCommand.allCases.count)
}

@MainActor @Test func aCancelledSkillReadShowsNoErrorAndKeepsTheRows() async throws {
  let rowsId = RequestId()
  let reads = Counter()
  // The first read answers; the second never does.
  let (workspace, _) = await makeWorkspace { method, args, id in
    guard method == "skill-rows" else { return skillScript(rows: nil)(method, args, id) }
    if reads.next() == 1 { return [reply(id, skillsJSON)] }
    rowsId.set(id)
    return []
  }
  await workspace.open("s1")
  await workspace.loadSkills()
  #expect(workspace.skillRows.count == 1)
  let reading = Task { await workspace.loadSkills() }
  try await eventually { rowsId.current != nil }
  reading.cancel()
  await reading.value
  #expect(workspace.errorMessage == nil)
  #expect(workspace.skillRows.count == 1)
}

@MainActor @Test func aSkillReadThatReturnsAfterASwitchLeavesTheNewRowsAlone() async throws {
  let rowsId = RequestId()
  let (workspace, backend) = await makeWorkspace(script: skillScript(rows: nil, rowsId: rowsId))
  await workspace.open("s1")
  let reading = Task { await workspace.loadSkills() }
  try await eventually { rowsId.current != nil }
  await workspace.open("s2")
  backend.push(reply(try #require(rowsId.current), skillsJSON))
  await reading.value
  #expect(workspace.view?.session.sessionId == "s2")
  #expect(workspace.skillRows.isEmpty)
}

@MainActor @Test func aSkillRefusesChips() async throws {
  let (workspace, backend) = await makeWorkspace(script: skillScript(rows: skillsJSON))
  await workspace.open("s1")
  await workspace.attach([URL(fileURLWithPath: "/d/a.txt")])
  workspace.draft = "/create-skill now"
  await workspace.runSkill(SkillInvocation(selector: "create-skill", arguments: "now"))
  #expect(workspace.errorMessage == Workspace.commandWithAttachments)
  #expect(workspace.draft == "/create-skill now")
  #expect(requests(backend).filter { $0.first == .string("send-skill") }.isEmpty)
}

@MainActor @Test func aSkillRunsAndClearsTheDraft() async throws {
  let (workspace, backend) = await makeWorkspace(script: skillScript(rows: skillsJSON))
  await workspace.open("s1")
  workspace.draft = "/create-skill now"
  await workspace.runSkill(SkillInvocation(selector: "create-skill", arguments: "now"))
  #expect(workspace.errorMessage == nil)
  #expect(workspace.draft.isEmpty)
  let sent = requests(backend).filter { $0.first == .string("send-skill") }
  #expect(sent.count == 1)
  guard case .array(let args)? = sent.first?.last, case .object(let input)? = args.first else {
    Issue.record("send-skill carried no input")
    return
  }
  #expect(input["sessionId"] == .string("s1"))
  #expect(input["selector"] == .string("create-skill"))
  #expect(input["arguments"] == .string("now"))
}

private let oddSkills = [
  SkillRow(selector: "release.notes", description: "Notes"),
  SkillRow(selector: "release notes now", description: "Spaced"),
  SkillRow(selector: "release", description: "Short"),
  SkillRow(selector: "clear-cache", description: "Cache"),
  SkillRow(selector: "clear cache", description: "Shadowed by /clear"),
]

@Test func anyListedSelectorCanBeRun() {
  #expect(
    SlashMenu.invocation("/release.notes x", skills: oddSkills)
      == SkillInvocation(selector: "release.notes", arguments: "x"))
  #expect(
    SlashMenu.invocation("/release notes now x y", skills: oddSkills)
      == SkillInvocation(selector: "release notes now", arguments: "x y"))
  // The longest known selector wins; a shorter one takes the rest as arguments.
  #expect(
    SlashMenu.invocation("/release notes later", skills: oddSkills)
      == SkillInvocation(selector: "release", arguments: "notes later"))
  #expect(SlashMenu.invocation("/release.notesx", skills: oddSkills) == nil)
  #expect(SlashMenu.invocation("/nothing here", skills: oddSkills) == nil)
  // A skill never shadows a command, even one whose name starts with a command word.
  #expect(SlashMenu.invocation("/clear cache", skills: oddSkills) == nil)
  #expect(!SlashMenu.rows(for: "/", skills: oddSkills).contains { $0.name == "clear cache" })
  #expect(SlashMenu.rows(for: "/release.", skills: oddSkills).map(\.name) == ["release.notes"])
  #expect(SlashMenu.rows(for: "/release n", skills: oddSkills).map(\.name) == ["release notes now"])
}

@Test func aSelectorIsMatchedWithoutCaseAndSentAsListed() {
  #expect(
    SlashMenu.invocation("/Create-Skill go", skills: skills)
      == SkillInvocation(selector: "create-skill", arguments: "go"))
  #expect(SlashMenu.keyAction(.enter, draft: "/Create-skill", index: 0, skills: skills) == .submit)
}

@Test func enterActsOnAHighlightMovedOffTheExactMatch() {
  let cache = [SkillRow(selector: "clear-cache", description: "Cache")]
  // Untouched: the exact command runs.
  #expect(SlashMenu.keyAction(.enter, draft: "/clear", index: 0, skills: cache) == .submit)
  // Moved to the skill row: that row is chosen.
  #expect(SlashMenu.keyAction(.enter, draft: "/clear", index: 1, skills: cache) == .setDraft("/clear-cache "))
  // An exact skill name that is not first still runs when it is highlighted.
  let short = [SkillRow(selector: "cl", description: "Short")]
  #expect(SlashMenu.keyAction(.enter, draft: "/cl", index: 1, skills: short) == .submit)
  #expect(SlashMenu.keyAction(.enter, draft: "/cl", index: 0, skills: short) == .submit)
}

@MainActor @Test func aSkillRunsWithTheEffortAndModeInForce() async throws {
  let (workspace, backend) = await makeWorkspace(
    preferences: Preferences(recentProjects: ["/p"], reasoningEffort: "low"),
    script: skillScript(rows: skillsJSON))
  await workspace.open("s1")
  workspace.mode = .steer
  await workspace.runSkill(SkillInvocation(selector: "create-skill", arguments: ""))
  let sent = requests(backend).filter { $0.first == .string("send-skill") }
  guard case .array(let args)? = sent.first?.last, case .object(let input)? = args.first else {
    Issue.record("send-skill carried no input")
    return
  }
  #expect(input["effort"] == .string("low"))
  #expect(input["mode"] == .string("steer"))
  #expect(input["arguments"] == nil)
}
