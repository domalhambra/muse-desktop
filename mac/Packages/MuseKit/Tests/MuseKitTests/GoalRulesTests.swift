import MuseBackend
import Testing
@testable import MuseKit

private let active = SessionGoal(objective: "Ship", status: "active", percentComplete: 40)
private let paused = SessionGoal(objective: "Ship", status: "paused", percentComplete: 0)

@Test func aGoalCommandSetsEditsOrRunsAVerb() {
  #expect(GoalRules.command("Ship it", goal: nil) == .set("Ship it"))
  #expect(GoalRules.command("Ship it", goal: active) == .edit("Ship it"))
  #expect(GoalRules.command("pause", goal: active) == .verb("pause"))
  #expect(GoalRules.command("RESUME", goal: paused) == .verb("resume"))
  #expect(GoalRules.command("clear", goal: active) == .verb("clear"))
  #expect(GoalRules.command("Pause the deploy", goal: active) == .edit("Pause the deploy"))
  #expect(GoalRules.command("", goal: active) == .help)
}

@Test func theStripOffersOnlyWhatTheStatusAllows() {
  #expect(GoalRules.canPause(active) && !GoalRules.canResume(active))
  #expect(GoalRules.canResume(paused) && !GoalRules.canPause(paused))
  let done = SessionGoal(objective: "Ship", status: "complete", percentComplete: 100)
  #expect(!GoalRules.canPause(done) && !GoalRules.canResume(done))
}

@Test func theStripDescribesTheGoal() {
  #expect(GoalRules.detail(active) == "Active · 40%")
  #expect(GoalRules.detail(paused) == "Paused")
  let over = SessionGoal(objective: "Ship", status: "complete", percentComplete: 120)
  #expect(GoalRules.detail(over) == "Complete · 120%")
}
