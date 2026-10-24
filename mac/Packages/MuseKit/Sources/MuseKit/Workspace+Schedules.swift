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
}
