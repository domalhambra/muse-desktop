import MuseBackend

/// Where the transcript offers a fork: the last completed Muse message of each completed turn.
public enum ForkRules {
  /// Item id to turn id. The active turn has no fork point: `session/fork` refuses it.
  public static func points(_ items: [TranscriptItem], activeTurnId: String?) -> [String: String] {
    var unfinished = Set<String>()
    var last: [String: String] = [:]
    for item in items where item.retracted != true {
      guard let turn = item.turnId else { continue }
      if item.status == "inProgress" { unfinished.insert(turn) }
      if item.kind == "agentMessage", item.status == "completed" { last[turn] = item.itemId }
    }
    if let activeTurnId { unfinished.insert(activeTurnId) }
    return Dictionary(
      uniqueKeysWithValues: last.filter { !unfinished.contains($0.key) }.map { ($0.value, $0.key) })
  }
}
