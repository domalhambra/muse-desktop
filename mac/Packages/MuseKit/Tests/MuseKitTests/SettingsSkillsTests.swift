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
  #expect(requests(backend).filter { $0.first == "skill-catalog" }.count == 1)
}
