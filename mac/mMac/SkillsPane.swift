import MuseBackend
import MuseKit
import SwiftUI

/// Settings › Skills: every skill Muse knows, and whether it is on. Errors show in the Settings
/// window's alert, through `settings`.
struct SkillsPane: View {
  let settings: SettingsModel

  var body: some View {
    Form {
      Section {
        Text("Skills teach Muse a task. Muse reads the changes you make here when it reconnects.")
          .foregroundStyle(.themeSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if settings.needsReconnect {
          HStack {
            Text("Reconnect Muse Code to apply your changes.")
            Spacer()
            Button("Reconnect") { Task { await settings.reconnect() } }
          }
        }
      }
      Section("Skills") {
        if settings.skills.isEmpty {
          Text("Muse Code reported no skills.").foregroundStyle(.themeSecondary)
        }
        ForEach(settings.skills) { skill in
          row(skill)
        }
      }
    }
    .formStyle(.grouped)
    .task { await settings.loadSkills() }
  }

  private func row(_ skill: SkillEntry) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(skill.displayName).bold()
        Text(skill.description).font(.caption).foregroundStyle(.themeSecondary).lineLimit(2)
        Text(skill.scope.capitalized).font(.caption2).foregroundStyle(.themeSecondary)
      }
      Spacer()
      Picker(
        "Activation",
        selection: Binding(
          get: { skill.activation },
          set: { next in Task { await settings.setSkill(skill, activation: next) } })
      ) {
        ForEach(SettingsRules.skillActivations(current: skill.activation), id: \.value) { option in
          Text(option.label).tag(option.value)
        }
      }
      .labelsHidden()
      .disabled(settings.changingSkills.contains(skill.id))
      .fixedSize()
      .accessibilityLabel("Activation for \(skill.displayName)")
      .accessibilityIdentifier("skill-activation-\(skill.name)")
    }
  }
}
