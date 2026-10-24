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
