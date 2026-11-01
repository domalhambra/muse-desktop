import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

private let goalView =
  #"{"session":\#(sessionJSON("s1")),"items":[],"approvals":[],"questions":[],"goal":{"objective":"Ship","status":"active","percentComplete":40}}"#

/// Answers `open` with s1 and a goal, `goal` with `answer`, and the rest with null.
private func goalScript(goal answer: @escaping @Sendable (Int) -> String) -> @Sendable (String, [JSONValue], Int) -> [String] {
  { method, _, id in
    switch method {
    case "open": [reply(id, goalView)]
    case "goal": [answer(id)]
    default: [reply(id, "null")]
    }
  }
}

private let noGoal = "This conversation has no goal."

@MainActor @Test func theStripSendsAGoalVerbForTheOpenConversation() async throws {
  let (workspace, backend) = await makeWorkspace(script: goalScript { reply($0, "null") })
  await workspace.open("s1")
  #expect(workspace.view?.goal?.objective == "Ship")
  await workspace.goal("edit", objective: "Ship it")
  #expect(requests(backend).last == [.string("goal"), .array([.string("s1"), .string("edit"), .string("Ship it")])])
  #expect(workspace.view?.goal != nil)
  #expect(workspace.errorMessage == nil)
}

@MainActor @Test func aRefusalForNoGoalRemovesTheStaleStrip() async throws {
  // Another client cleared the goal while this host was unsubscribed: the reopened view is stale.
  let (workspace, _) = await makeWorkspace(script: goalScript { failure($0, noGoal) })
  await workspace.open("s1")
  #expect(workspace.view?.goal != nil)
  await workspace.goal("pause")
  #expect(workspace.errorMessage == noGoal)
  #expect(workspace.view?.goal == nil)
  #expect(workspace.view?.session.sessionId == "s1")
}

@MainActor @Test func theGoalCommandAlsoRemovesTheStaleStrip() async throws {
  let (workspace, _) = await makeWorkspace(script: goalScript { failure($0, noGoal) })
  await workspace.open("s1")
  workspace.draft = "/goal resume"
  let command = try #require(ComposerCommand.parse(workspace.draft))
  await workspace.run(command)
  #expect(workspace.errorMessage == noGoal)
  #expect(workspace.view?.goal == nil)
}

@MainActor @Test func anotherRefusalKeepsTheStrip() async throws {
  let sentence = "The goal cannot do that in its current state."
  let (workspace, _) = await makeWorkspace(script: goalScript { failure($0, sentence) })
  await workspace.open("s1")
  await workspace.goal("resume")
  #expect(workspace.errorMessage == sentence)
  #expect(workspace.view?.goal?.objective == "Ship")
}

@MainActor @Test func twoQuickForkClicksMakeOneFork() async throws {
  let forks = Counter()
  let (workspace, backend) = await makeWorkspace(script: { method, args, id in
    switch method {
    case "open":
      let target = args.first == .string("f1") ? "f1" : "s1"
      return [reply(id, viewJSON(sessionJSON(target)))]
    case "fork":
      forks.next()
      return [reply(id, viewJSON(sessionJSON("f1")))]
    default: return [reply(id, "null")]
    }
  })
  await workspace.open("s1")
  async let first: Void = workspace.fork(fromTurn: "t1")
  async let second: Void = workspace.fork(fromTurn: "t1")
  _ = await (first, second)
  #expect(forks.value == 1)
  #expect(workspace.view?.session.sessionId == "f1")
  #expect(!workspace.forking)
  // Once the first has finished, a fork works again.
  await workspace.fork()
  #expect(forks.value == 2)
  #expect(requests(backend).filter { $0.first == .string("fork") }.count == 2)
}
