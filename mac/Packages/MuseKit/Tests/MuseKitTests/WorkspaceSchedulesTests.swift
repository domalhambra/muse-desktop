import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

private let entry = #"{"schedule":{"id":"a","name":"Morning review","prompt":"Review.","folder":"/p","preset":"manual","minute":0,"hour":9,"weekday":1,"approvalMode":"onRequest","modelId":null,"worktree":false,"enabled":true,"createdAt":1},"nextRunAt":null,"history":[]}"#

@MainActor @Test func schedulesLoadAndActionsReload() async throws {
  let lists = Counter()
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "schedule-list": lists.next(); return [reply(id, "[\(entry)]")]
    case "schedule-save": return [reply(id, entry)]
    default: return [reply(id, "null")]
    }
  }
  await workspace.loadSchedules()
  #expect(workspace.schedules.map(\.schedule.name) == ["Morning review"])
  await workspace.runSchedule(id: "a")
  await workspace.setScheduleEnabled(id: "a", enabled: false)
  await workspace.removeSchedule(id: "a")
  let input = ScheduleInput(name: "Morning review", prompt: "Review.", folder: "/p", preset: "manual", minute: 0,
                            hour: 9, weekday: 1, approvalMode: "onRequest")
  #expect(await workspace.saveSchedule(input) == nil)
  #expect(lists.value == 5)
  #expect(requests(backend).contains([.string("schedule-run"), .array([.string("a")])]))
  #expect(requests(backend).contains([.string("schedule-enabled"), .array([.string("a"), .bool(false)])]))
  #expect(requests(backend).contains([.string("schedule-remove"), .array([.string("a")])]))
  #expect(requests(backend).contains { $0.first == .string("schedule-save") })
}

@MainActor @Test func aFormProblemIsReturnedWithoutCallingTheBackend() async throws {
  let (workspace, backend) = await makeWorkspace { _, _, id in [reply(id, "null")] }
  let input = ScheduleInput(name: "", prompt: "Review.", folder: "/p", preset: "manual", minute: 0, hour: 9,
                            weekday: 1, approvalMode: "onRequest")
  #expect(await workspace.saveSchedule(input) == "Give the task a name.")
  #expect(!requests(backend).contains { $0.first == .string("schedule-save") })
}

@MainActor @Test func aScheduledRunIsRememberedForItsNotice() async throws {
  let lists = Counter()
  let (workspace, _) = await makeWorkspace { method, _, id in
    if method == "schedule-list" { lists.next(); return [reply(id, "[\(entry)]")] }
    return [reply(id, "null")]
  }
  workspace.apply(.scheduleRunStarted(scheduleId: "a", name: "Morning review", sessionId: "s1"))
  #expect(workspace.scheduledRuns["s1"] == "Morning review")
  try await eventually { workspace.schedules.count == 1 }
  workspace.apply(.schedulesChanged)
  try await eventually { lists.value == 2 }
}

@MainActor @Test(.timeLimit(.minutes(1))) func anOlderListReplyKeepsTheNewerList() async throws {
  // The first list request gets no scripted reply: the test sends it after the second one lands.
  let lists = Counter()
  let (workspace, backend) = await makeWorkspace { method, _, id in
    guard method == "schedule-list" else { return [reply(id, "null")] }
    return lists.next() == 1 ? [] : [reply(id, "[\(entry)]")]
  }
  let first = Task { await workspace.loadSchedules() }
  try await eventually { lists.value == 1 }
  await workspace.loadSchedules()
  #expect(workspace.schedules.count == 1)
  guard case .number(let id)? = backend.messages.first(where: { $0["method"] == "schedule-list" })?["id"]
  else { Issue.record("no schedule-list id"); return }
  backend.push(reply(Int(id), "[]"))
  await first.value
  #expect(workspace.schedules.count == 1)
}

@MainActor @Test func aScheduledRunNamesOnlyTheTurnThatFinishesIt() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "schedule-list" ? [reply(id, "[\(entry)]")] : [reply(id, "null")]
  }
  workspace.apply(.scheduleRunStarted(scheduleId: "a", name: "Morning review", sessionId: "s1"))
  let running = try decodeView(viewJSON(sessionJSON("s1", status: "running"))).session
  let idle = try decodeView(viewJSON(sessionJSON("s1", status: "idle"))).session
  // A status that is not a finished turn keeps the entry.
  #expect(workspace.finishScheduledRun(running, previous: nil) == nil)
  #expect(workspace.scheduledRuns["s1"] == "Morning review")
  // The turn that finishes takes the name, once.
  #expect(workspace.finishScheduledRun(idle, previous: "running") == "Morning review")
  #expect(workspace.scheduledRuns["s1"] == nil)
  // A later turn in that conversation is an ordinary one.
  #expect(workspace.finishScheduledRun(idle, previous: "running") == nil)
}
