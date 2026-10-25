import MuseBackend

extension Workspace {
  /// Reads the task list. A failure keeps the list shown. A reply that lands after a newer read
  /// started is dropped, so an older list never replaces a newer one.
  public func loadSchedules() async {
    schedulesSequence += 1
    let sequence = schedulesSequence
    guard let next = try? await client.schedules(), sequence == schedulesSequence else { return }
    schedules = next
  }

  /// Saves a new or changed task. Returns the form's message, or nil when it saved.
  public func saveSchedule(_ input: ScheduleInput) async -> String? {
    if let problem = ScheduleRules.validate(input) { return problem }
    do {
      _ = try await client.saveSchedule(input)
    } catch {
      return error.localizedDescription
    }
    await loadSchedules()
    return nil
  }

  public func removeSchedule(id: String) async {
    await run { try await self.client.removeSchedule(id: id) }
    await loadSchedules()
  }

  public func runSchedule(id: String) async {
    await run { try await self.client.runSchedule(id: id) }
    await loadSchedules()
  }

  public func setScheduleEnabled(id: String, enabled: Bool) async {
    await run { try await self.client.setScheduleEnabled(id: id, enabled: enabled) }
    await loadSchedules()
  }

  /// The task's name when this `session` event ends the turn a scheduled run started, or nil. It
  /// forgets the run either way, so only that first turn's notice names the task: a later turn in
  /// the same conversation is the person's own, and a turn that ended while mMac was focused (no
  /// notice) still ends the run.
  public func finishScheduledRun(_ session: Session, previous: String?) -> String? {
    guard previous == "running", session.status != "running" else { return nil }
    return scheduledRuns.removeValue(forKey: session.sessionId)
  }
}
