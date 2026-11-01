import MuseBackend
import MuseKit
import SwiftUI

/// The goal strip above the composer: the objective, the status and the controls Muse allows.
struct GoalStrip: View {
  let goal: SessionGoal
  let workspace: Workspace
  @State private var editing = false
  @State private var objective = ""

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "target").foregroundStyle(.themeSecondary).accessibilityHidden(true)
      Text(goal.objective).lineLimit(1).truncationMode(.tail)
        .accessibilityIdentifier("goal-objective")
      Text(GoalRules.detail(goal)).font(.caption).foregroundStyle(.themeSecondary).lineLimit(1)
        .fixedSize()
        .accessibilityIdentifier("goal-detail")
      Spacer(minLength: 4)
      if GoalRules.canPause(goal) {
        Button("Pause") { Task { await workspace.goal("pause") } }
          .accessibilityIdentifier("goal-pause")
      }
      if GoalRules.canResume(goal) {
        Button("Resume") { Task { await workspace.goal("resume") } }
          .accessibilityIdentifier("goal-resume")
      }
      Button("Edit") {
        objective = goal.objective
        editing = true
      }
      Button("Clear") { Task { await workspace.goal("clear") } }
        .accessibilityIdentifier("goal-clear")
    }
    .controlSize(.small)
    .accessibilityElement(children: .contain)
    .alert("Edit goal", isPresented: $editing) {
      TextField("Objective", text: $objective)
      Button("Save") { Task { await workspace.goal("edit", objective: objective) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(GoalRules.startsWork)
    }
  }
}
