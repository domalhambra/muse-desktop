import Foundation
import MuseBackendTesting
import Testing
@testable import MuseBackend

let fullViewJSON = #"""
  {"session":{"sessionId":"s1","workspaceRoot":"/p","createdAt":"2026-10-21T00:00:00Z","updatedAt":"2026-10-21T01:00:00Z","lastActivityAt":"2026-10-21T01:00:00Z","status":"running","activeTurnId":"t1","modelId":"m1","name":"Named","title":"Title","firstUserPrompt":"First","turnCount":2,"kind":"main","worktree":{"path":"/p/.muse/worktrees/w","origin":"created"}},
   "items":[
    {"itemId":"r1","kind":"reasoning","revision":2,"status":"completed","summary":["One","Two"]},
    {"itemId":"t1","kind":"toolCall","revision":3,"status":"completed","tool":"shell","args":"{\"cmd\":\"ls\"}","visibleOutput":"a\nb","commandText":"ls","statusLine":"Listed","durationMs":1234,"truncated":true,"outputRef":{"id":"o1","byteLen":99},"patchSummary":{"added":3,"removed":1,"files":1},"result":{"text":"done"}},
    {"itemId":"x1","kind":"reminderChild","revision":1,"status":"inProgress","reminderAgentId":"r","blocking":true}
   ],
   "approvals":[{"approvalId":"a1","sessionId":"s1","toolName":"shell","rawArgs":"rm -rf x","currentRequirementId":{"approvalId":"a1","sourceIndex":0},"subject":{"kind":"command","command":"rm -rf x"},"availableChoices":[{"choiceId":"c1","label":"Allow once","decision":"approved","scope":"once"},{"choiceId":"c2","label":"Always allow","decision":"approvedForSession","scope":"localPersistent","rulePreview":"Allow rm"}]}],
   "questions":[{"userInputId":"u1","sessionId":"s1","questions":[{"id":"q1","header":"Pick","question":"Which one?","options":[{"label":"A","description":"First"},{"label":"B"}],"selection":{"mode":"multiple","minSelections":1,"maxSelections":2}}]}],
   "usage":{"input":1,"output":2,"total":3},"error":"Boom"}
  """#

@Test func aFullSessionViewDecodes() throws {
  let view = try JSONDecoder().decode(SessionView.self, from: Data(fullViewJSON.utf8))
  #expect(view.session.worktree?.path == "/p/.muse/worktrees/w")
  #expect(view.session.lastActivityAt == "2026-10-21T01:00:00Z")
  #expect(view.items[0].summary == ["One", "Two"])
  let tool = view.items[1]
  #expect(tool.tool == "shell")
  #expect(tool.durationMs == 1234)
  #expect(tool.outputRef?.id == "o1")
  #expect(tool.patchSummary?.added == 3)
  #expect(tool.result?.text == "done")
  #expect(tool.truncated == true)
  #expect(view.items[2].blocking == true)
  #expect(view.approvals[0].availableChoices[1].rulePreview == "Allow rm")
  #expect(view.approvals[0].subject.command == "rm -rf x")
  #expect(view.questions[0].questions[0].selection.maxSelections == 2)
  #expect(view.questions[0].questions[0].options[0].description == "First")
  #expect(view.error == "Boom")
}

@Test func aPreferencesEventDecodes() throws {
  let line = #"{"type":"preferences","preferences":{"theme":"muse","cliPath":"","recentProjects":["/p"],"trustedProjects":[],"reasoningEffort":"high","archivedSessionIds":[],"pinnedSessionIds":[]}}"#
  let event = try JSONDecoder().decode(AppEvent.self, from: Data(line.utf8))
  guard case .preferences(let preferences) = event else {
    Issue.record("Expected a preferences event")
    return
  }
  #expect(preferences.recentProjects == ["/p"])
  #expect(preferences.reasoningEffort == "high")
}

@Test func typedCallsSendTheBackendsArgumentShapes() async throws {
  let backend = ScriptedBackend { message in
    guard case .number(let number)? = message["id"] else { return [] }
    let id = Int(number)
    switch message["method"] {
    case "models":
      return [#"{"id":\#(id),"ok":true,"value":[{"modelId":"m1","displayLabel":"Model One","providerId":"p","isDefault":true,"isActive":true,"contextLimit":null}]}"#]
    case "output":
      return [#"{"id":\#(id),"ok":true,"value":"stored"}"#]
    case "preferences":
      return [#"{"id":\#(id),"ok":true,"value":{"cliPath":"","recentProjects":[],"trustedProjects":[],"reasoningEffort":"low"}}"#]
    case "create":
      return [#"{"id":\#(id),"ok":true,"value":\#(fullViewJSON)}"#]
    case "sessions":
      return [#"{"id":\#(id),"ok":true,"value":{"sessions":[],"nextCursor":null}}"#]
    default:
      return [#"{"id":\#(id),"ok":true,"value":null}"#]
    }
  }
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  _ = try await client.sessions(cursor: "c1")
  try await client.rename(sessionId: "s1", name: "New name")
  #expect(try await client.models(sessionId: "s1").first?.displayLabel == "Model One")
  _ = try await client.models()
  try await client.setModel(sessionId: "s1", modelId: "m1")
  try await client.approve(sessionId: "s1", approvalId: "a1", choiceId: "c1")
  try await client.answer(
    sessionId: "s1", userInputId: "u1",
    answers: [QuestionAnswer(questionId: "q1", selectedLabel: "A")])
  try await client.cancelQuestion(sessionId: "s1", userInputId: "u1")
  #expect(try await client.readOutput(sessionId: "s1", itemId: "i1") == "stored")
  #expect(try await client.preferences(PreferencesPatch(reasoningEffort: "low")).reasoningEffort == "low")
  try await client.send(sessionId: "s1", text: "hi", effort: "max", mode: .steer)
  _ = try await client.create(project: "/p", modelId: "m1")
  _ = try await client.create(project: "/p")
  let sent: [[JSONValue]] = backend.messages.map { [$0["method"] ?? .null, $0["args"] ?? .null] }
  #expect(sent == [
    ["sessions", ["c1"]],
    ["rename", ["s1", "New name"]],
    ["models", ["s1"]],
    ["models", []],
    ["set-model", ["s1", "m1"]],
    ["approve", ["s1", "a1", "c1"]],
    ["answer", ["s1", "u1", [["questionId": "q1", "selectedLabel": "A"]]]],
    ["cancel-question", ["s1", "u1"]],
    ["output", ["s1", "i1"]],
    ["preferences", [["reasoningEffort": "low"]]],
    ["send", [["sessionId": "s1", "text": "hi", "attachments": [], "effort": "max", "mode": "steer"]]],
    ["create", ["/p", "m1"]],
    ["create", ["/p"]],
  ])
}
