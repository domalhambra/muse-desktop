import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

private let limitsJSON = #"{"observedAt":1,"tier":"pro","window":{"usedPercent":42,"resetsAt":2,"minutes":300},"weekly":{"usedPercent":18,"resetsAt":3}}"#

@MainActor @Test func beginReadsTheLimitsAndEventsReplaceThem() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "sessions": [reply(id, #"{"sessions":[],"nextCursor":null}"#)]
    case "models": [reply(id, "[]")]
    case "usage": [reply(id, limitsJSON)]
    default: [reply(id, "null")]
    }
  }
  await workspace.begin()
  #expect(workspace.limits?.window.usedPercent == 42)
  workspace.apply(.usageChanged(SubscriptionLimits(
    observedAt: 4, tier: "pro", window: .init(usedPercent: 85, resetsAt: 5, minutes: 300),
    weekly: .init(usedPercent: 30, resetsAt: 6))))
  #expect(workspace.limits?.window.usedPercent == 85)
  workspace.apply(.usageChanged(nil))
  #expect(workspace.limits == nil)
}

@MainActor @Test func aLostConnectionClearsTheLimits() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "usage" ? [reply(id, limitsJSON)] : [reply(id, "null")]
  }
  await workspace.loadLimits()
  #expect(workspace.limits != nil)
  workspace.apply(.connection(ConnectionStatus(state: "error", message: "closed")))
  #expect(workspace.limits == nil)
}

@MainActor @Test(.timeLimit(.minutes(1))) func aLimitsReplyAfterTheConnectionDropsIsIgnored() async throws {
  // The usage request gets no scripted reply: the test replies after the connection drops.
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "usage" ? [] : [reply(id, "null")]
  }
  let load = Task { await workspace.loadLimits() }
  try await eventually { backend.messages.contains { $0["method"] == "usage" } }
  guard case .number(let id)? = backend.messages.first(where: { $0["method"] == "usage" })?["id"]
  else { Issue.record("no usage id"); return }
  workspace.apply(.connection(ConnectionStatus(state: "error", message: "closed")))
  backend.push(reply(Int(id), limitsJSON))
  await load.value
  #expect(workspace.limits == nil)
}

@MainActor @Test func anOlderLimitsReplyKeepsTheNewerEvent() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "usage" ? [reply(id, limitsJSON)] : [reply(id, "null")]
  }
  workspace.apply(.usageChanged(SubscriptionLimits(
    observedAt: 10, tier: "pro", window: .init(usedPercent: 85, resetsAt: 20, minutes: 300),
    weekly: .init(usedPercent: 30, resetsAt: 30))))
  await workspace.loadLimits()
  #expect(workspace.limits?.observedAt == 10)
  #expect(workspace.limits?.window.usedPercent == 85)
}

@MainActor @Test func aLimitsReplyAsNewAsTheEventReplacesIt() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "usage" ? [reply(id, limitsJSON)] : [reply(id, "null")]
  }
  workspace.apply(.usageChanged(SubscriptionLimits(
    observedAt: 1, tier: "pro", window: .init(usedPercent: 85, resetsAt: 2, minutes: 300),
    weekly: .init(usedPercent: 30, resetsAt: 3))))
  await workspace.loadLimits()
  #expect(workspace.limits?.window.usedPercent == 42)
}
