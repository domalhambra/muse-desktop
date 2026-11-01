import MuseBackend
import Testing
@testable import MuseKit

private func message(_ id: String, turn: String?, status: String = "completed", kind: String = "agentMessage")
  -> TranscriptItem
{
  TranscriptItem(itemId: id, kind: kind, revision: 1, status: status, turnId: turn)
}

@Test func aForkPointIsTheLastCompletedMessageOfACompletedTurn() {
  let items = [
    message("u1", turn: "t1", kind: "userMessage"),
    message("a1", turn: "t1"),
    message("a2", turn: "t1"),
    message("u2", turn: "t2", kind: "userMessage"),
    message("a3", turn: "t2"),
    message("a4", turn: "t3", status: "inProgress"),
  ]
  #expect(ForkRules.points(items, activeTurnId: nil) == ["a2": "t1", "a3": "t2"])
  #expect(ForkRules.points(items, activeTurnId: "t2") == ["a2": "t1"])
}

@Test func anItemWithNoTurnIsNotAForkPoint() {
  #expect(ForkRules.points([message("a1", turn: nil)], activeTurnId: nil).isEmpty)
}
