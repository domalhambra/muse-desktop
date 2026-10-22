import MuseBackend
import MuseKit
import SwiftUI

/// Electron's Appearance tab, with mMac's two themes. Every change saves through `SettingsModel`,
/// so its errors show on the Settings window.
struct AppearancePane: View {
  let settings: SettingsModel
  let notifications: any NotificationPermission

  private var preferences: Preferences { settings.workspace.preferences }

  var body: some View {
    let theme = ThemeName(preference: preferences.theme)
    Form {
      Section("Theme") {
        HStack(spacing: 12) {
          ForEach(ThemeName.allCases) { option in
            ThemeCard(theme: option, selected: option == theme) {
              Task { await settings.save(PreferencesPatch(theme: option.rawValue)) }
            }
          }
        }
      }
      Section {
        Picker(
          "Text size",
          selection: binding(TextSize(preference: preferences.fontSize)) { size in
            PreferencesPatch(fontSize: size.rawValue)
          }
        ) {
          ForEach(TextSize.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        Toggle("Reduce motion", isOn: binding(preferences.reduceMotion) { PreferencesPatch(reduceMotion: $0) })
          .toggleStyle(.switch)
        Toggle(isOn: notificationBinding) {
          Text("Completion notifications")
          Text("Show a notification when a turn finishes in the background.")
        }
        .toggleStyle(.switch)
      }
    }
    .formStyle(.grouped)
  }

  private func binding<Value>(_ value: Value, patch: @escaping (Value) -> PreferencesPatch) -> Binding<Value> {
    Binding(get: { value }, set: { next in Task { await settings.save(patch(next)) } })
  }

  /// Turning notifications on asks macOS for permission first, and saves nothing when refused.
  private var notificationBinding: Binding<Bool> {
    Binding(
      get: { preferences.notifyOnCompletion },
      set: { on in
        Task {
          if on, !(await notifications.requestPermission()) { return }
          await settings.save(PreferencesPatch(notifyOnCompletion: on))
        }
      })
  }
}

private struct ThemeCard: View {
  let theme: ThemeName
  let selected: Bool
  let choose: () -> Void

  var body: some View {
    Button(action: choose) {
      VStack(alignment: .leading, spacing: 6) {
        ThemeBackground(palette: theme.palette)
          .overlay(alignment: .bottomTrailing) {
            Circle().fill(Color(hex: theme.palette.accent)).frame(width: 14, height: 14).padding(8)
          }
          .frame(width: 150, height: 80)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: selected ? 2 : 1))
        Text(theme.label).font(.headline)
        Text(theme.hint).font(.caption).foregroundStyle(.secondary)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("theme-\(theme.rawValue)")
  }
}

/// Asks macOS whether mMac may post notifications.
@MainActor protocol NotificationPermission {
  func requestPermission() async -> Bool
}

/// Stands in until `Notifications` asks macOS: it grants every request without asking.
struct GrantedNotificationPermission: NotificationPermission {
  func requestPermission() async -> Bool { true }
}
