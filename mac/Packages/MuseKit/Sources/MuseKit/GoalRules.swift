import MuseBackend

/// The goal strip's rules and the `/goal` grammar. Muse's status is a free string, so an unknown
/// status shows as it is and offers only Edit and Clear.
public enum GoalRules {
  public enum Command: Equatable, Sendable {
    case set(String)
    case edit(String)
    case verb(String)
    case help
  }

  public static let help = "Use /goal <objective>, /goal pause, /goal resume, or /goal clear."
  /// Shown in the goal strip's Edit alert: a goal costs allowance.
  public static let startsWork = "Setting a goal starts Muse working on it."

  /// A lone `pause`, `resume` or `clear` is a verb. Any other text is the objective.
  public static func command(_ argument: String, goal: SessionGoal?) -> Command {
    let lowered = argument.lowercased()
    if argument.isEmpty { return .help }
    if ["pause", "resume", "clear"].contains(lowered) { return .verb(lowered) }
    return goal == nil ? .set(argument) : .edit(argument)
  }

  public static func canPause(_ goal: SessionGoal) -> Bool { goal.status == "active" }
  public static func canResume(_ goal: SessionGoal) -> Bool { goal.status == "paused" }

  /// "Active · 40%". The percent shows only above zero, and may pass 100.
  public static func detail(_ goal: SessionGoal) -> String {
    let status = goal.status.prefix(1).uppercased() + goal.status.dropFirst()
    guard goal.percentComplete > 0 else { return status }
    return "\(status) · \(Int(goal.percentComplete))%"
  }
}
