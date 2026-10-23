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
    case "git-status":
      return [#"{"id":\#(id),"ok":true,"value":{"branch":"main","isRepository":true,"changes":[{"path":"a.txt","status":"M","staged":false}]}}"#]
    case "git-diff", "git-raw-diff", "read-file":
      return [#"{"id":\#(id),"ok":true,"value":"text"}"#]
    case "files":
      return [#"{"id":\#(id),"ok":true,"value":[{"name":"src","path":"src","directory":true}]}"#]
    case "worktrees":
      return [#"{"id":\#(id),"ok":true,"value":[{"path":"/p","branch":"main","isMain":true,"sessionIds":[]},{"path":"/p/.muse/worktrees/w","isMain":false,"sessionIds":["s1"]}]}"#]
    case "worktree-merge":
      return [#"{"id":\#(id),"ok":true,"value":{"ok":false,"output":"Merging muse/w has conflicts"}}"#]
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
  _ = try await client.create(project: "/p", worktree: true)
  _ = try await client.create(project: "/p", modelId: "m1", worktree: true)
  #expect(try await client.gitStatus(project: "/p").changes == [GitChange(path: "a.txt", status: "M", staged: false)])
  #expect(try await client.gitDiff(project: "/p", path: "a.txt") == "text")
  #expect(try await client.gitRawDiff(project: "/p", path: "a.txt") == "text")
  try await client.revertFile(project: "/p", path: "a.txt")
  try await client.revertHunk(project: "/p", path: "a.txt", index: 2)
  try await client.stageFile(project: "/p", path: "a.txt")
  #expect(try await client.files(project: "/p").first?.directory == true)
  _ = try await client.files(project: "/p", directory: "src")
  #expect(try await client.readFile(project: "/p", path: "a.txt") == "text")
  let worktrees = try await client.worktrees(project: "/p")
  #expect(worktrees.map(\.branch) == ["main", nil])
  let merge = try await client.mergeWorktree(project: "/p", path: "/p/.muse/worktrees/w")
  #expect(merge.ok == false)
  #expect(merge.output == "Merging muse/w has conflicts")
  try await client.removeWorktree(project: "/p", path: "/p/.muse/worktrees/w")
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
    ["create", ["/p", nil, ["worktree": true]]],
    ["create", ["/p", "m1", ["worktree": true]]],
    ["git-status", ["/p"]],
    ["git-diff", ["/p", "a.txt"]],
    ["git-raw-diff", ["/p", "a.txt"]],
    ["git-revert-file", ["/p", "a.txt"]],
    ["git-revert-hunk", ["/p", "a.txt", 2]],
    ["git-stage-file", ["/p", "a.txt"]],
    ["files", ["/p", ""]],
    ["files", ["/p", "src"]],
    ["read-file", ["/p", "a.txt"]],
    ["worktrees", ["/p"]],
    ["worktree-merge", ["/p", "/p/.muse/worktrees/w"]],
    ["worktree-remove", ["/p", "/p/.muse/worktrees/w"]],
  ])
}

@Test func usageDecodesWhenPresentAndIsNilWhenAbsent() throws {
  let session = #"{"sessionId":"s1","workspaceRoot":null,"updatedAt":"2026-10-21T00:00:00Z","status":"idle","activeTurnId":null,"modelId":null}"#
  let with = try JSONDecoder().decode(
    SessionView.self,
    from: Data(#"{"session":\#(session),"items":[],"approvals":[],"questions":[],"usage":{"input":10,"output":5,"total":15}}"#.utf8))
  #expect(with.usage == Usage(input: 10, output: 5, total: 15))
  let without = try JSONDecoder().decode(
    SessionView.self, from: Data(#"{"session":\#(session),"items":[],"approvals":[],"questions":[]}"#.utf8))
  #expect(without.usage == nil)
}

@Test func theEffortListMatchesElectron() {
  #expect(ReasoningEffort.allCases.map(\.rawValue) == ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
  #expect(ReasoningEffort.xhigh.label == "Extra high")
  #expect(ReasoningEffort.medium.label == "Medium")
}

@Test func cardModelsHavePublicInitializers() {
  let choice = Approval.Choice(choiceId: "c", label: "Allow once", decision: "approved", scope: "once")
  let approval = Approval(
    approvalId: "a", sessionId: "s", toolName: "shell", rawArgs: "ls",
    subject: Approval.Subject(kind: "command", command: "ls"), availableChoices: [choice])
  #expect(approval.availableChoices.first?.label == "Allow once")
  let question = UserQuestion(
    userInputId: "u", sessionId: "s",
    questions: [
      UserQuestion.Prompt(
        id: "q", header: "H", question: "Which?", options: [UserQuestion.Option(label: "A")],
        selection: UserQuestion.Selection(mode: "single"))
    ])
  #expect(question.questions.first?.options.first?.label == "A")
  let model = MuseModel(modelId: "m", displayLabel: "M", providerId: "p", isDefault: true, isActive: true)
  #expect(model.contextLimit == nil)
}

@Test func aReasoningSummaryWithGapsKeepsItsStrings() throws {
  // muse-host.ts fills summary by index, so a skipped index arrives as null.
  let line = #"{"itemId":"r1","kind":"reasoning","revision":1,"status":"inProgress","summary":["One",null,"Three"]}"#
  let item = try JSONDecoder().decode(TranscriptItem.self, from: Data(line.utf8))
  #expect(item.summary == ["One", "Three"])
}

@Test func preferencesDecodeEveryFieldWithElectronsDefaults() throws {
  let empty = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
  #expect(empty.theme == "muse")
  #expect(empty.fontSize == "comfortable")
  #expect(!empty.reduceMotion && !empty.notifyOnCompletion)
  #expect(!empty.bridgeFilesEnabled && !empty.bridgeMcpEnabled)
  #expect(empty.bridgeMcpPort == 7735)
  #expect(empty == Preferences())
  let full = try JSONDecoder().decode(
    Preferences.self,
    from: Data(#"{"theme":"moonlight","fontSize":"large","reduceMotion":true,"notifyOnCompletion":true,"bridgeFilesEnabled":true,"bridgeMcpEnabled":true,"bridgeMcpPort":8000}"#.utf8))
  #expect(full.theme == "moonlight" && full.fontSize == "large" && full.bridgeMcpPort == 8000)
  #expect(full.reduceMotion && full.notifyOnCompletion && full.bridgeFilesEnabled && full.bridgeMcpEnabled)
}

@Test func aPatchSendsOnlyItsFields() throws {
  let data = try JSONEncoder().encode(PreferencesPatch(theme: "moonlight", bridgeMcpPort: 7736))
  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(object?.keys.sorted() == ["bridgeMcpPort", "theme"])
  let every = PreferencesPatch(
    cliPath: "/m", reasoningEffort: "low", theme: "muse", fontSize: "large", reduceMotion: true,
    notifyOnCompletion: true, bridgeFilesEnabled: true, bridgeMcpEnabled: false, bridgeMcpPort: 7735)
  let all = try JSONSerialization.jsonObject(with: JSONEncoder().encode(every)) as? [String: Any]
  #expect(all?.keys.sorted() == [
    "bridgeFilesEnabled", "bridgeMcpEnabled", "bridgeMcpPort", "cliPath", "fontSize",
    "notifyOnCompletion", "reasoningEffort", "reduceMotion", "theme",
  ])
  #expect(PreferencesPatch(bridgeMcpEnabled: true).touchesBridges)
  #expect(!PreferencesPatch(theme: "muse").touchesBridges)
}

@Test func pinsAndArchivesDecodeWithEmptyDefaultsAndTravelInAPatch() throws {
  let empty = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
  #expect(empty.pinnedSessionIds.isEmpty)
  #expect(empty.archivedSessionIds.isEmpty)
  let saved = try JSONDecoder().decode(
    Preferences.self, from: Data(#"{"pinnedSessionIds":["a","b"],"archivedSessionIds":["c"]}"#.utf8))
  #expect(saved.pinnedSessionIds == ["a", "b"])
  #expect(saved.archivedSessionIds == ["c"])
  #expect(saved == Preferences(pinnedSessionIds: ["a", "b"], archivedSessionIds: ["c"]))
  let pin = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PreferencesPatch(pinnedSessionIds: ["a"])))
    as? [String: Any]
  #expect(pin?.keys.sorted() == ["pinnedSessionIds"])
  #expect(pin?["pinnedSessionIds"] as? [String] == ["a"])
  // An empty list is sent: restoring the last archived conversation saves [].
  let archive = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(PreferencesPatch(archivedSessionIds: []))) as? [String: Any]
  #expect(archive?.keys.sorted() == ["archivedSessionIds"])
  #expect(!PreferencesPatch(pinnedSessionIds: ["a"], archivedSessionIds: ["b"]).touchesBridges)
}

@Test func mcpShapesRoundTrip() throws {
  let list = try JSONDecoder().decode(
    McpServerList.self,
    from: Data(#"{"file":"/c/settings.json","servers":[{"name":"files","transport":"stdio","enabled":true,"command":"npx","args":["-y"],"envNames":["TOKEN"]},{"name":"remote","transport":"http","enabled":false,"url":"https://e.com/mcp","headerNames":[]}]}"#.utf8))
  #expect(list.file == "/c/settings.json")
  #expect(list.servers.map(\.name) == ["files", "remote"])
  #expect(list.servers[0].isRemote == false && list.servers[1].isRemote)
  #expect(list.servers[0].detail == "npx -y" && list.servers[1].detail == "https://e.com/mcp")
  #expect(list.servers[0].secretNames == ["TOKEN"] && list.servers[1].secretNames.isEmpty)
  let stdio = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(McpServerInput.stdio(name: "a", command: "node", args: ["x"], env: ["K": "v"])))
    as? [String: Any]
  #expect(stdio?["transport"] as? String == "stdio" && stdio?["args"] as? [String] == ["x"])
  #expect(stdio?["name"] as? String == "a" && stdio?["command"] as? String == "node")
  #expect(stdio?["env"] as? [String: String] == ["K": "v"])
  let http = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(McpServerInput.http(name: "b", url: "https://e.com", headers: [:])))
    as? [String: Any]
  #expect(http?["transport"] as? String == "http" && http?["url"] as? String == "https://e.com")
  #expect(http?["headers"] as? [String: String] == [:])
}

@Test func bridgeStatusDecodes() throws {
  let status = try JSONDecoder().decode(
    BridgeStatus.self,
    from: Data(#"{"folder":"/d/bridge","files":{"enabled":true,"running":false,"error":"x"},"mcp":{"enabled":true,"running":true,"url":"http://127.0.0.1:7735/mcp","hasToken":true},"activeJobs":1}"#.utf8))
  #expect(status.files.error == "x" && status.mcp.hasToken && status.activeJobs == 1)
  #expect(status.folder == "/d/bridge" && status.mcp.url == "http://127.0.0.1:7735/mcp" && status.mcp.error == nil)
}

@Test func settingsModelsHavePublicInitializers() {
  let server = McpServer(name: "a", transport: "stdio", enabled: true, command: "node", args: ["x"])
  #expect(server.detail == "node x")
  #expect(McpServerList(file: "/f", servers: [server]).servers.count == 1)
  let status = BridgeStatus(
    folder: "/b", files: BridgeStatus.Part(enabled: false, running: false),
    mcp: BridgeStatus.Mcp(enabled: true, running: false, url: "http://127.0.0.1:7735/mcp", hasToken: false),
    activeJobs: 0)
  #expect(status.mcp.error == nil)
}

@Test func sessionUsageCanChange() {
  var view = SessionView(session: Session(sessionId: "s", updatedAt: "2026-10-21T00:00:00Z"))
  view.usage = Usage(input: 1, output: 2, total: 3)
  #expect(view.usage?.total == 3)
}

@Test func compactResultDecodes() throws {
  let result = try JSONDecoder().decode(CompactResult.self, from: Data(#"{"status":"noop"}"#.utf8))
  #expect(result == CompactResult(status: "noop"))
}

@Test func attachmentRoundTrips() throws {
  let json = #"{"id":"a1","name":"shot.png","kind":"image","size":2048}"#
  let attachment = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
  #expect(attachment == Attachment(id: "a1", name: "shot.png", kind: "image", size: 2048))
  #expect(try JSONDecoder().decode(Attachment.self, from: JSONEncoder().encode(attachment)) == attachment)
}
