import MuseBackend

/// One open workflow run in the Agents tab.
public struct WorkflowRow: Equatable, Sendable, Identifiable {
  public let id: String
  public let runId: String
  public let title: String
  public let paused: Bool

  public static func build(_ items: [TranscriptItem]) -> [WorkflowRow] {
    items.compactMap { item in
      guard item.kind == "workflow", item.retracted != true, item.stopAvailable == true,
        let runId = item.workflowRunId
      else { return nil }
      return WorkflowRow(
        id: item.itemId, runId: runId,
        title: ToolPresentation.first(item.objective, item.label) ?? "Workflow",
        paused: item.paused == true)
    }
  }
}

/// A tool running in the turn's foreground, which Muse may send to the background.
public struct RunningToolRow: Equatable, Sendable, Identifiable {
  public let id: String
  public let title: String

  public static func build(_ items: [TranscriptItem], listed: [BackgroundTask]) -> [RunningToolRow] {
    let background = Set(listed.map(\.taskId))
    return items.compactMap { item in
      guard item.kind == "toolCall", item.status == "inProgress", item.retracted != true,
        item.background != true, !background.contains(item.itemId)
      else { return nil }
      return RunningToolRow(id: item.itemId, title: ToolPresentation.first(item.tool) ?? "Tool")
    }
  }
}

public enum BackgroundRules {
  public static let stopAllTitle = "Stop all background tasks?"
  public static let stopAllDetail = "Muse stops every background task in this conversation."

  /// Muse has no event for `task/list`, but each task that starts or ends changes an item, and a
  /// tool moved to the background gets its `background` flag by `item/updated`. The tab reads the
  /// list again when this value changes.
  public static func signature(_ items: [TranscriptItem]) -> String {
    items.filter {
      $0.status == "inProgress" && ["toolCall", "subagent", "workflow"].contains($0.kind)
    }
    .map { $0.background == true ? "\($0.itemId):bg" : $0.itemId }.sorted().joined(separator: ",")
  }

  /// A task row's name: its tool when it has one, else its kind.
  public static func title(_ task: BackgroundTask) -> String { task.tool ?? task.kind }
}
