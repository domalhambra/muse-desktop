import MuseBackend

extension Workspace {
  /// Reads the latest limits. A failure keeps what the events gave: the footer is a convenience.
  /// A reply that lands after the connection stopped being ready is dropped, so it cannot bring
  /// back the limits that the lost connection cleared.
  public func loadLimits() async {
    guard let next = try? await client.usage(), status.isReady else { return }
    limits = next
  }
}
