import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

private func item(
  _ id: String, _ kind: String, _ status: String = "inProgress", run: String? = nil,
  paused: Bool? = nil, stop: Bool? = nil, subagent: String? = nil, tool: String? = nil
) -> TranscriptItem {
  TranscriptItem(
    itemId: id, kind: kind, revision: 1, status: status, tool: tool, subagentId: subagent,
    workflowRunId: run, paused: paused, stopAvailable: stop)
}

@Test func workflowRowsKeepOpenRuns() {
  let rows = WorkflowRow.build([
    item("w1", "workflow", run: "r1", paused: true, stop: true),
    item("w2", "workflow", "completed", run: "r2", stop: false),
    item("w3", "workflow", run: nil, stop: true),
  ])
  #expect(rows.map(\.runId) == ["r1"])
  #expect(rows[0].paused)
}

@Test func runningToolsLeaveOutListedTasks() {
  let items = [
    item("t1", "toolCall", tool: "bash"), item("t2", "toolCall", tool: "grep"),
    item("t3", "toolCall", "completed", tool: "ls"),
  ]
  let rows = RunningToolRow.build(items, listed: [BackgroundTask(taskId: "t2", kind: "tool")])
  #expect(rows.map(\.id) == ["t1"])
  #expect(rows[0].title == "bash")
}

@Test func aSubagentCanStopOnlyWhileRunning() {
  let running = AgentRow.build([item("a1", "subagent", subagent: "s1")])[0]
  #expect(running.canStop)
  #expect(running.subagentId == "s1")
  #expect(!AgentRow.build([item("a2", "subagent", "completed", subagent: "s2")])[0].canStop)
  #expect(!AgentRow.build([item("a3", "subagent")])[0].canStop)
}

@Test func theSignatureFollowsTheRunningSet() {
  let one = BackgroundRules.signature([item("t1", "toolCall"), item("m1", "agentMessage")])
  let same = BackgroundRules.signature([item("t1", "toolCall"), item("m2", "agentMessage")])
  let two = BackgroundRules.signature([item("t1", "toolCall"), item("t2", "toolCall")])
  #expect(one == same)
  #expect(one != two)
}

@MainActor @Test func withNoConversationNoTaskListIsRead() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "task-list"
      ? [reply(id, #"[{"taskId":"k1","kind":"tool","status":"inProgress"}]"#)]
      : [reply(id, "null")]
  }
  await workspace.loadTasks()
  #expect(workspace.backgroundTasks.isEmpty)
  #expect(requests(backend).filter { $0.first == "task-list" }.isEmpty)
}
