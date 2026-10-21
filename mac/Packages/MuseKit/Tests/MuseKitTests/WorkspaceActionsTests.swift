import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

private let approvalJSON = #"[{"approvalId":"a1","sessionId":"s1","toolName":"shell","rawArgs":"ls","subject":{"kind":"command","command":"ls"},"availableChoices":[{"choiceId":"c1","label":"Allow once","decision":"approved","scope":"once"}]}]"#
private let questionJSON = #"[{"userInputId":"u1","sessionId":"s1","questions":[{"id":"q1","header":"Pick","question":"Which?","options":[{"label":"A"}],"selection":{"mode":"single"}}]}]"#

/// Answers `open` with conversation s1 and every other call with `null`, unless `extra` answers it.
private func openScript(
  _ extra: @escaping @Sendable (String, [JSONValue], Int) -> [String]? = { _, _, _ in nil }
) -> @Sendable (String, [JSONValue], Int) -> [String] {
  { method, args, id in
    if let answer = extra(method, args, id) { return answer }
    if method == "open" {
      return [reply(id, viewJSON(sessionJSON("s1"), approvals: approvalJSON, questions: questionJSON))]
    }
    return [reply(id, "null")]
  }
}

/// The id of the last request for `method`.
private func lastId(_ backend: ScriptedBackend, _ method: String) -> Int? {
  guard case .number(let id)? = backend.messages.last(where: { $0["method"] == .string(method) })?["id"]
  else { return nil }
  return Int(id)
}

@MainActor @Test func sendingWithoutAProjectAsksForOne() async throws {
  let (workspace, backend) = await makeWorkspace(preferences: Preferences())
  workspace.draft = "hi"
  #expect(await workspace.send() == .needsProject)
  #expect(backend.messages.isEmpty)
  #expect(workspace.draft == "hi")
}

@MainActor @Test func theFirstSendCreatesTheConversation() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "create" ? [reply(id, viewJSON(sessionJSON("s1")))] : [reply(id, "null")]
  }
  workspace.draft = "hi"
  #expect(await workspace.send() == .sent)
  #expect(requests(backend) == [
    ["create", ["/p"]],
    ["send", [["sessionId": "s1", "text": "hi", "attachments": [], "effort": "high", "mode": "queue"]]],
  ])
  #expect(workspace.view?.items.last?.text == "hi")
  #expect(workspace.view?.items.last?.kind == "userMessage")
  #expect(workspace.isRunning)
  #expect(workspace.draft == "")
}

@MainActor @Test func aFailedSendRestoresTheDraft() async throws {
  let (workspace, _) = await makeWorkspace(script: openScript { method, _, id in
    method == "send" ? [failure(id, "Project trust was cancelled. No session was started.")] : nil
  })
  await workspace.open("s1")
  workspace.draft = "hi"
  #expect(await workspace.send() == .notSent)
  #expect(workspace.draft == "hi")
  #expect(workspace.view?.items.isEmpty == true)
  #expect(workspace.view?.session.status == "idle")
  #expect(workspace.errorMessage == "Project trust was cancelled. No session was started.")
}

@MainActor @Test func steerAndEffortTravelWithTheMessage() async throws {
  let (workspace, backend) = await makeWorkspace(
    preferences: Preferences(recentProjects: ["/p"], reasoningEffort: "max"), script: openScript())
  await workspace.open("s1")
  workspace.mode = .steer
  workspace.draft = "now"
  _ = await workspace.send()
  #expect(requests(backend).last == [
    "send", [["sessionId": "s1", "text": "now", "attachments": [], "effort": "max", "mode": "steer"]],
  ])
}

@MainActor @Test func theDefaultModelIsChosenAndModelsChangeWhereTheyShould() async throws {
  let models = #"[{"modelId":"m1","displayLabel":"One","providerId":"p","isDefault":false,"isActive":true,"contextLimit":null},{"modelId":"m2","displayLabel":"Two","providerId":"p","isDefault":true,"isActive":true,"contextLimit":null}]"#
  let (workspace, backend) = await makeWorkspace(script: openScript { method, _, id in
    method == "models" ? [reply(id, models)] : nil
  })
  await workspace.loadModels()
  #expect(workspace.modelId == "m2")
  await workspace.chooseModel("m1")
  #expect(workspace.modelId == "m1")
  #expect(!backend.messages.contains { $0["method"] == "set-model" })
  await workspace.open("s1")
  await workspace.chooseModel("m2")
  #expect(requests(backend).last == ["set-model", ["s1", "m2"]])
  #expect(workspace.modelId == "m2")
}

@MainActor @Test func effortIsSavedAsAPreference() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "preferences"
      ? [reply(id, #"{"cliPath":"","recentProjects":["/p"],"trustedProjects":[],"reasoningEffort":"low"}"#)] : []
  }
  await workspace.chooseEffort("low")
  #expect(workspace.effort == "low")
  #expect(requests(backend) == [["preferences", [["reasoningEffort": "low"]]]])
}

@MainActor @Test func renameTrimsAndRefusesBlank() async throws {
  let (workspace, backend) = await makeWorkspace(script: openScript())
  await workspace.open("s1")
  #expect(await workspace.rename("   ") == false)
  #expect(await workspace.rename("  New name  "))
  #expect(requests(backend).last == ["rename", ["s1", "New name"]])
}

@MainActor @Test func cardsCallTheBackend() async throws {
  let (workspace, backend) = await makeWorkspace(script: openScript())
  await workspace.open("s1")
  let view = try #require(workspace.view)
  await workspace.approve(view.approvals[0], choice: view.approvals[0].availableChoices[0])
  await workspace.answer(view.questions[0], answers: [QuestionAnswer(questionId: "q1", selectedLabel: "A")])
  await workspace.skip(view.questions[0])
  #expect(Array(requests(backend).suffix(3)) == [
    ["approve", ["s1", "a1", "c1"]],
    ["answer", ["s1", "u1", [["questionId": "q1", "selectedLabel": "A"]]]],
    ["cancel-question", ["s1", "u1"]],
  ])
  #expect(workspace.decidingApprovals.isEmpty)
  #expect(workspace.answeringQuestions.isEmpty)
}

@MainActor @Test func storedOutputIsReadOnce() async throws {
  let (workspace, backend) = await makeWorkspace(script: openScript { method, _, id in
    method == "output" ? [reply(id, #""full output""#)] : nil
  })
  await workspace.open("s1")
  let item = TranscriptItem(itemId: "t1", kind: "toolCall", status: "completed")
  await workspace.readOutput(item)
  await workspace.readOutput(item)
  #expect(workspace.storedOutput["t1"] == "full output")
  #expect(backend.messages.filter { $0["method"] == "output" }.count == 1)
}

@MainActor @Test func stopCancelsTheOpenConversation() async throws {
  let (workspace, backend) = await makeWorkspace(script: openScript())
  await workspace.open("s1")
  await workspace.stop()
  #expect(requests(backend).last == ["cancel", ["s1"]])
}

@MainActor @Test func aCustomCLIPathIsSavedThenReconnectReopens() async throws {
  let (workspace, backend) = await makeWorkspace(script: openScript { method, _, id in
    switch method {
    case "preferences": [reply(id, #"{"cliPath":"/opt/muse","recentProjects":["/p"],"trustedProjects":[],"reasoningEffort":"high"}"#)]
    case "connect": [reply(id, #"{"state":"ready","version":"1.4.11"}"#)]
    default: nil
    }
  })
  await workspace.open("s1")
  await workspace.setCLIPath("/opt/muse")
  #expect(workspace.preferences.cliPath == "/opt/muse")
  #expect(Array(requests(backend).suffix(3)) == [
    ["preferences", [["cliPath": "/opt/muse"]]],
    ["connect", []],
    ["open", ["s1"]],
  ])
}

// Stale replies. Electron's submit and setModel snapshot the open sequence and check it after the
// await, so a reply for a conversation the person has left does not change the one now shown.

@MainActor @Test func aModelReplyAfterOpeningAnotherConversationIsIgnored() async throws {
  // set-model gets no answer until the test pushes one.
  let (workspace, backend) = await makeWorkspace { method, args, id in
    switch method {
    case "open":
      args.first == "s1"
        ? [reply(id, viewJSON(sessionJSON("s1", modelId: "m1")))]
        : [reply(id, viewJSON(sessionJSON("s2", modelId: "m3")))]
    case "set-model": []
    default: [reply(id, "null")]
    }
  }
  await workspace.open("s1")
  let choosing = Task { await workspace.chooseModel("m2") }
  try await eventually { backend.messages.contains { $0["method"] == "set-model" } }
  await workspace.open("s2")
  #expect(workspace.modelId == "m3")
  let id = try #require(lastId(backend, "set-model"))
  backend.push(reply(id, "null"))
  await choosing.value
  #expect(workspace.modelId == "m3")
}

@MainActor @Test func clickingTheShownConversationKeepsAModelReply() async throws {
  // Nothing is opening, so the click changes nothing and the reply still applies.
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "open": [reply(id, viewJSON(sessionJSON("s1", modelId: "m1")))]
    case "set-model": []
    default: [reply(id, "null")]
    }
  }
  await workspace.open("s1")
  let choosing = Task { await workspace.chooseModel("m2") }
  try await eventually { backend.messages.contains { $0["method"] == "set-model" } }
  await workspace.open("s1")
  let id = try #require(lastId(backend, "set-model"))
  backend.push(reply(id, "null"))
  await choosing.value
  #expect(workspace.modelId == "m2")
}

@MainActor @Test func aFirstSendAfterOpeningAnotherConversationLeavesItShown() async throws {
  // create gets no answer until the test pushes one; the person opens s2 meanwhile.
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "create": []
    case "open": [reply(id, viewJSON(sessionJSON("s2", root: "/q")))]
    default: [reply(id, "null")]
    }
  }
  workspace.draft = "hi"
  let sending = Task { await workspace.send() }
  try await eventually { backend.messages.contains { $0["method"] == "create" } }
  await workspace.open("s2")
  let id = try #require(lastId(backend, "create"))
  backend.push(reply(id, viewJSON(sessionJSON("s1"))))
  #expect(await sending.value == .sent)
  // Electron still sends to the conversation it created.
  #expect(requests(backend).last == [
    "send", [["sessionId": "s1", "text": "hi", "attachments": [], "effort": "high", "mode": "queue"]],
  ])
  #expect(workspace.view?.session.sessionId == "s2")
  #expect(workspace.view?.items.isEmpty == true)
  #expect(workspace.view?.session.status == "idle")
  #expect(workspace.drafts["new:/p"] == nil)
  #expect(workspace.draft == "")
  #expect(!workspace.submitting)
}

@MainActor @Test func aFailedSendAfterOpeningAnotherConversationLeavesItAlone() async throws {
  // send gets no answer until the test pushes a failure; the person opens a running s2 meanwhile.
  let (workspace, backend) = await makeWorkspace { method, args, id in
    switch method {
    case "open":
      args.first == "s1"
        ? [reply(id, viewJSON(sessionJSON("s1")))]
        : [reply(id, viewJSON(sessionJSON("s2", status: "running")))]
    case "send": []
    default: [reply(id, "null")]
    }
  }
  await workspace.open("s1")
  workspace.draft = "hi"
  let sending = Task { await workspace.send() }
  try await eventually { backend.messages.contains { $0["method"] == "send" } }
  await workspace.open("s2")
  let id = try #require(lastId(backend, "send"))
  backend.push(failure(id, "boom"))
  #expect(await sending.value == .notSent)
  #expect(workspace.view?.session.sessionId == "s2")
  #expect(workspace.view?.session.status == "running")
  #expect(workspace.draft == "")
  // The draft goes back to the conversation it was written in.
  #expect(workspace.drafts["s1"] == "hi")
  #expect(workspace.errorMessage == "boom")
  #expect(!workspace.submitting)
}

@MainActor @Test func aFailedSendKeepsWhatThePersonTypedSince() async throws {
  let (workspace, backend) = await makeWorkspace(script: openScript { method, _, _ in
    method == "send" ? [] : nil
  })
  await workspace.open("s1")
  workspace.draft = "hi"
  let sending = Task { await workspace.send() }
  try await eventually { backend.messages.contains { $0["method"] == "send" } }
  #expect(workspace.draft == "")
  #expect(workspace.view?.items.last?.text == "hi")
  workspace.draft = "next"
  let id = try #require(lastId(backend, "send"))
  backend.push(failure(id, "boom"))
  #expect(await sending.value == .notSent)
  #expect(workspace.draft == "next")
  #expect(workspace.view?.items.isEmpty == true)
}
