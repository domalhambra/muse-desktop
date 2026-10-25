import MuseBackend

extension Workspace {
  /// Reads the latest limits. A failure keeps what the events gave: the footer is a convenience.
  /// A reply that lands after the connection stopped being ready is dropped, so it cannot bring
  /// back the limits that the lost connection cleared. A reply older than the limits a
  /// `usage-changed` event gave during the read is dropped too: the event is newer.
  public func loadLimits() async {
    guard let next = try? await client.usage(), status.isReady else { return }
    if let current = limits, next.observedAt < current.observedAt { return }
    limits = next
  }
}
