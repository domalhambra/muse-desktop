import MuseBackend

extension Workspace {
  /// Reads the task list. A failure keeps the list shown.
  public func loadSchedules() async {
    guard let next = try? await client.schedules() else { return }
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
