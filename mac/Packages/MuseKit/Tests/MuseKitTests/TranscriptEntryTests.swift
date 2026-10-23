import Foundation
import MuseBackend
import Testing
@testable import MuseKit

private func tool(_ id: String, status: String = "completed", title: String? = nil) -> TranscriptItem {
  TranscriptItem(itemId: id, kind: "toolCall", status: status, tool: title ?? "shell")
}

private func message(_ id: String, _ kind: String = "agentMessage") -> TranscriptItem {
  TranscriptItem(itemId: id, kind: kind, status: "completed", text: "x")
}

@Test func hiddenItemsNeverShow() {
  let items = [
    message("u", "userMessage"),
    TranscriptItem(itemId: "r", kind: "reminderChild", status: "completed"),
    TranscriptItem(itemId: "h", kind: "hookRun", status: "completed"),
    TranscriptItem(itemId: "gone", kind: "agentMessage", status: "completed", retracted: true),
    message("a"),
  ]
  #expect(TranscriptEntry.build(items).map(\.id) == ["u", "a"])
}

@Test func threeCompletedToolsGroupButTwoDoNot() {
  let grouped = TranscriptEntry.build([tool("1"), tool("2"), tool("3"), message("m"), tool("4"), tool("5")])
  #expect(grouped.map(\.id) == ["group-1", "m", "4", "5"])
  guard case .toolGroup(let members) = grouped[0] else {
    Issue.record("Expected a group")
    return
  }
  #expect(members.map(\.itemId) == ["1", "2", "3"])
}

@Test func anUnfinishedToolEndsARun() {
  let entries = TranscriptEntry.build([tool("1"), tool("2"), tool("3", status: "inProgress"), tool("4")])
  #expect(entries.map(\.id) == ["1", "2", "3", "4"])
}

@Test func toolLabelsFollowElectron() {
  #expect(ToolPresentation.title(TranscriptItem(itemId: "a", kind: "toolCall", status: "completed")) == "tool call")
  #expect(ToolPresentation.title(TranscriptItem(itemId: "a", kind: "webSearch", status: "completed", label: "Search")) == "Search")
  let item = TranscriptItem(
    itemId: "a", kind: "toolCall", status: "completed", args: #"{"b":1}"#, visibleOutput: "out",
    commandText: "ls", fallbackText: "fallback", durationMs: 1234,
    patchSummary: .init(added: 3, removed: 1, files: 1))
  #expect(ToolPresentation.summary(item) == "ls")
  #expect(ToolPresentation.output(item, stored: nil) == "out")
  #expect(ToolPresentation.output(item, stored: "stored") == "stored")
  #expect(ToolPresentation.formattedArgs(#"{"b":1}"#) == "{\n  \"b\": 1\n}")
  #expect(ToolPresentation.formattedArgs("not json") == "not json")
  // JSON.stringify leaves slashes alone; Foundation escapes them unless told not to.
  #expect(ToolPresentation.formattedArgs(#"{"path":"/etc/hosts"}"#) == "{\n  \"path\": \"/etc/hosts\"\n}")
  #expect(ToolPresentation.patch(item) == "+3 \u{2212}1")
  #expect(ToolPresentation.footer(item) == "completed · 1.2s")
}

@Test func numbersInToolInputPrintAsTyped() {
  #expect(ToolPresentation.formattedArgs(#"{"a":0.7,"b":3.14,"c":[1,2]}"#)
    == "{\n  \"a\": 0.7,\n  \"b\": 3.14,\n  \"c\": [\n    1,\n    2\n  ]\n}")
  #expect(ToolPresentation.formattedArgs("0.7") == "0.7")
  #expect(ToolPresentation.formattedArgs("{not json") == "{not json")
  #expect(ToolPresentation.formattedArgs(#"{"n":-0,"m":1e300}"#) == "{\n  \"n\": -0,\n  \"m\": 1e300\n}")
}

@Test func emptyToolInputPrintsOnOneLine() {
  // JSON.stringify(value, null, 2) writes {} and [].
  #expect(ToolPresentation.formattedArgs("{}") == "{}")
  #expect(ToolPresentation.formattedArgs("[ ]") == "[]")
  #expect(ToolPresentation.formattedArgs(#"{"a":{},"b":[],"c":"{\n}"}"#)
    == "{\n  \"a\": {},\n  \"b\": [],\n  \"c\": \"{\\n}\"\n}")
}

@Test func toolInputKeepsItsKeyOrderAndStringsAsTyped() {
  #expect(ToolPresentation.formattedArgs(#"{"zeta":"a \"quoted\" , : word","alpha":true}"#)
    == "{\n  \"zeta\": \"a \\\"quoted\\\" , : word\",\n  \"alpha\": true\n}")
  // A string that starts with a combining mark: the quote and the mark are one Character.
  #expect(ToolPresentation.formattedArgs("{\"a\":\"\u{301}x y\"}") == "{\n  \"a\": \"\u{301}x y\"\n}")
  // Windows line ends between tokens are layout too.
  #expect(ToolPresentation.formattedArgs("{\r\n  \"a\": [\r\n  ]\r\n}") == "{\n  \"a\": []\n}")
}

@Test func durationsRoundAsToFixedDoes() {
  func footer(_ ms: Double) -> String {
    ToolPresentation.footer(TranscriptItem(itemId: "a", kind: "toolCall", status: "completed", durationMs: ms))
  }
  // An exact tie rounds away from zero; 1.15 and 2.35 are not exact in binary, so they do not tie.
  #expect(footer(1250) == "completed · 1.3s")
  #expect(footer(250) == "completed · 0.3s")
  #expect(footer(1750) == "completed · 1.8s")
  #expect(footer(1150) == "completed · 1.1s")
  #expect(footer(2350) == "completed · 2.4s")
  #expect(footer(25) == "completed · 0.0s")
  #expect(ToolPresentation.footer(TranscriptItem(itemId: "a", kind: "toolCall", status: "failed")) == "failed")
}

@Test func patchCountsShowOnEveryToolWithASummary() {
  let zero = TranscriptItem(
    itemId: "z", kind: "toolCall", status: "completed", patchSummary: .init(added: 0, removed: 0, files: 0))
  #expect(ToolPresentation.patch(zero) == "+0 \u{2212}0")
  #expect(ToolPresentation.patch(tool("n")) == nil)
  #expect(ToolPresentation.groupPatch([zero, zero, zero]) == nil)
  #expect(TranscriptEntry.toolGroup([]).id == "group-empty")
}

@Test func groupLabelsNameUpToThreeTools() {
  let items = [tool("1", title: "read"), tool("2", title: "read"), tool("3", title: "write"), tool("4", title: "grep"), tool("5", title: "ls")]
  #expect(ToolPresentation.groupTitle(items) == "Ran 5 tools")
  #expect(ToolPresentation.groupDetail(items) == "read, write, grep")
}

@Test func messageAndReasoningText() {
  let user = TranscriptItem(itemId: "u", kind: "userMessage", status: "completed", text: "<context>x</context>Hi there")
  #expect(ToolPresentation.messageText(user) == "Hi there")
  let reasoning = TranscriptItem(itemId: "r", kind: "reasoning", status: "completed", summary: ["One", "Two"])
  #expect(ToolPresentation.reasoningText(reasoning) == "One\n\nTwo")
  #expect(ToolPresentation.reasoningText(TranscriptItem(itemId: "r", kind: "reasoning", status: "completed"))
    == "No reasoning text was provided by the model.")
}

@Test func onlyBackgroundWorkRunning() {
  let reminder = TranscriptItem(itemId: "r", kind: "reminderChild", status: "inProgress")
  #expect(Activity.isBackgroundOnly([reminder]))
  #expect(!Activity.isBackgroundOnly([reminder, tool("t", status: "inProgress")]))
  #expect(!Activity.isBackgroundOnly([]))
}

@Test func oneHelperSplitsACamelCaseKindForTheTranscriptAndTheActivityTab() {
  // As Electron's `kind.replace(/([A-Z])/g, ' $1')`.
  #expect(ToolPresentation.words("mcpToolCall") == "mcp Tool Call")
  #expect(ToolPresentation.words("plain") == "plain")
  // The transcript lowercases it; the Activity tab capitalises its first letter.
  #expect(ToolPresentation.spaced("mcpToolCall") == "mcp tool call")
  #expect(ActivityEntry.titled("mcpToolCall") == "Mcp Tool Call")
}

@Test func aUserShellItemIsItsOwnRowAndNeverGroups() {
  let shell = TranscriptItem(
    itemId: "sh", kind: "userShell", status: "completed", visibleOutput: "hi\n", commandText: "echo hi",
    durationMs: 12, exitCode: 0)
  let entries = TranscriptEntry.build([tool("1"), tool("2"), shell, tool("3"), tool("4"), tool("5")])
  #expect(entries.map(\.id) == ["1", "2", "sh", "group-3"])
  guard case .shell(let item) = entries[2] else {
    Issue.record("Expected a shell row")
    return
  }
  #expect(item.commandText == "echo hi")
  #expect(ToolPresentation.shellFooter(shell) == "completed · exit 0 · 0.0s")
  #expect(ToolPresentation.shellFooter(TranscriptItem(itemId: "r", kind: "userShell", status: "inProgress")) == "Running")
  #expect(ToolPresentation.shellFooter(TranscriptItem(itemId: "f", kind: "userShell", status: "failed", exitCode: 2)) == "failed · exit 2")
}

@Test func aSideChatItemIsOneRow() {
  let item = TranscriptItem(itemId: "sc", kind: "sideChat", status: "completed", sideSessionId: "side-1")
  let entries = TranscriptEntry.build([tool("1"), item, tool("2")])
  #expect(entries.map(\.id) == ["1", "sc", "2"])
  guard case .sideChat(let row) = entries[1] else {
    Issue.record("Expected a side chat row")
    return
  }
  #expect(row.sideSessionId == "side-1")
}
