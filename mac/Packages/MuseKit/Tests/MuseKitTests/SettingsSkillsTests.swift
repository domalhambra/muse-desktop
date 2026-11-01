import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

private let catalog = #"[{"id":"bundled:a","name":"a","displayName":"A","description":"d","scope":"bundled","activation":"on"}]"#

@MainActor @Test func changingASkillReloadsAndAsksForAReconnect() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "skill-catalog" ? [reply(id, catalog)] : [reply(id, "null")]
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.loadSkills()
  #expect(settings.skills.map(\.id) == ["bundled:a"])
  #expect(!settings.needsReconnect)
  await settings.setSkill(settings.skills[0], activation: "off")
  #expect(settings.needsReconnect)
  #expect(requests(backend).filter { $0.first == "skill-set" }.count == 1)
  #expect(requests(backend).filter { $0.first == "skill-catalog" }.count == 2)
}

@MainActor @Test func aRefusedSkillChangeShowsTheErrorAndKeepsTheReconnectNoticeAsItWas() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "skill-catalog": [reply(id, catalog)]
    case "skill-set": [failure(id, "Muse could not change the skill.")]
    default: [reply(id, "null")]
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.loadSkills()
  await settings.setSkill(settings.skills[0], activation: "off")
  #expect(settings.errorMessage == "Muse could not change the skill.")
  #expect(!settings.needsReconnect)
  // The catalog is read again, so the row shows the state Muse kept.
  #expect(requests(backend).filter { $0.first == "skill-catalog" }.count == 2)
}

@MainActor @Test func aRefusalStaysShownWhenTheRereadFailsToo() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "skill-set": [failure(id, "Muse could not change the skill.")]
    default: [reply(id, catalog)]
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.loadSkills()
  await settings.setSkill(settings.skills[0], activation: "off")
  #expect(settings.errorMessage == "Muse could not change the skill.")
  #expect(!settings.needsReconnect)
}

@MainActor @Test func aRefusalRereadsAndKeepsTheStateMuseHas() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "skill-catalog": [reply(id, catalog)]
    case "skill-set": [failure(id, "no")]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.loadSkills()
  await settings.setSkill(settings.skills[0], activation: "off")
  #expect(settings.skills.map(\.activation) == ["on"])
}

@MainActor @Test func aSecondChangeToTheSameSkillWaitsOutTheFirst() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "skill-catalog": [reply(id, catalog)]
    default: []  // skill-set waits for the reply pushed below
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.loadSkills()
  let skill = settings.skills[0]
  let first = Task { await settings.setSkill(skill, activation: "off") }
  try await eventually { backend.messages.contains { $0["method"] == "skill-set" } }
  #expect(settings.changingSkills == [skill.id])
  await settings.setSkill(skill, activation: "on")
  #expect(requests(backend).filter { $0.first == "skill-set" }.count == 1)
  guard case .number(let id)? = backend.messages.first(where: { $0["method"] == "skill-set" })?["id"] else {
    Issue.record("No skill-set request")
    return
  }
  backend.push(reply(Int(id), "null"))
  await first.value
  #expect(settings.changingSkills.isEmpty)
  #expect(requests(backend).filter { $0.first == "skill-set" }.count == 1)
}

@MainActor @Test func aSkillReadThatEndsAfterANewerOneIsDropped() async throws {
  let other = #"[{"id":"bundled:b","name":"b","displayName":"B","description":"d","scope":"bundled","activation":"on"}]"#
  let (workspace, backend) = await makeWorkspace { _, _, _ in [] }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  func id(_ index: Int) -> Int? {
    let sent = backend.messages.filter { $0["method"] == "skill-catalog" }
    guard index < sent.count, case .number(let id)? = sent[index]["id"] else { return nil }
    return Int(id)
  }
  let older = Task { await settings.loadSkills() }
  try await eventually { id(0) != nil }
  let newer = Task { await settings.loadSkills() }
  try await eventually { id(1) != nil }
  backend.push(reply(id(1)!, other))
  await newer.value
  backend.push(reply(id(0)!, catalog))
  await older.value
  #expect(settings.skills.map(\.id) == ["bundled:b"])
}

@MainActor @Test func aChangeDuringAReconnectKeepsTheSkillNotice() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "skill-catalog": [reply(id, catalog)]
    case "skill-set": [reply(id, "null")]
    default: []  // connect waits for the reply pushed below
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.loadSkills()
  await settings.setSkill(settings.skills[0], activation: "off")
  let reconnecting = Task { await settings.reconnect() }
  try await eventually { backend.messages.contains { $0["method"] == "connect" } }
  await settings.setSkill(settings.skills[0], activation: "on")
  guard case .number(let id)? = backend.messages.first(where: { $0["method"] == "connect" })?["id"] else {
    Issue.record("No connect request")
    return
  }
  backend.push(reply(Int(id), #"{"state":"ready","version":"1.4.11"}"#))
  await reconnecting.value
  #expect(settings.needsReconnect)
}

@Test func theActivationOptionsAlwaysIncludeTheCurrentValue() {
  #expect(SettingsRules.skillActivations(current: "userInvocableOnly").map(\.value) == ["on", "userInvocableOnly", "off"])
  let unknown = SettingsRules.skillActivations(current: "newer")
  #expect(unknown.map(\.value) == ["on", "userInvocableOnly", "off", "newer"])
  #expect(unknown.last?.label == "newer")
}
