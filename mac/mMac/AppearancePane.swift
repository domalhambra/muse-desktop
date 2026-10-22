import MuseBackend
import MuseKit
import SwiftUI

/// Electron's Appearance tab, with mMac's two themes. Every change saves through `SettingsModel`,
/// so its errors show on the Settings window.
struct AppearancePane: View {
  let settings: SettingsModel
  let notifications: any NotificationPermission
  /// The choices still being saved. Each control shows its own until the save answers, so it
  /// does not snap back to the old value meanwhile. A save that succeeds has already put the
  /// value in the Workspace's preferences; one that fails shows the saved value again.
  @State private var pending = PreferencesPatch()

  private var preferences: Preferences { settings.workspace.preferences }

  var body: some View {
    let theme = ThemeName(preference: pending.theme ?? preferences.theme)
    Form {
      Section("Theme") {
        HStack(spacing: 12) {
          ForEach(ThemeName.allCases) { option in
            ThemeCard(theme: option, selected: option == theme) {
              save(\.theme, option.rawValue)
            }
          }
        }
      }
      Section {
        Picker("Text size", selection: textSizeBinding) {
          ForEach(TextSize.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        // The stock selected segment: the theme's light accent under a white label is unreadable.
        .tint(nil)
        Toggle("Reduce motion", isOn: binding(\.reduceMotion, saved: preferences.reduceMotion))
          .toggleStyle(.switch)
        Toggle(isOn: notificationBinding) {
          Text("Completion notifications")
          Text("Show a notification when a turn finishes in the background.")
            .foregroundStyle(.themeSecondary)
        }
        .toggleStyle(.switch)
      }
    }
    .formStyle(.grouped)
  }

  /// Shows `value` at once and saves it.
  private func save<Value: Equatable>(_ key: WritableKeyPath<PreferencesPatch, Value?>, _ value: Value) {
    pending[keyPath: key] = value
    Task {
      var patch = PreferencesPatch()
      patch[keyPath: key] = value
      await settings.save(patch)
      // A later choice may still be saving; it clears its own.
      if pending[keyPath: key] == value { pending[keyPath: key] = nil }
    }
  }

  private func binding<Value: Equatable>(_ key: WritableKeyPath<PreferencesPatch, Value?>, saved: Value) -> Binding<Value> {
    Binding(get: { pending[keyPath: key] ?? saved }, set: { save(key, $0) })
  }

  private var textSizeBinding: Binding<TextSize> {
    Binding(
      get: { TextSize(preference: pending.fontSize ?? preferences.fontSize) },
      set: { save(\.fontSize, $0.rawValue) })
  }

  /// Turning notifications on asks macOS for permission first, and saves nothing when refused.
  private var notificationBinding: Binding<Bool> {
    Binding(
      get: { pending.notifyOnCompletion ?? preferences.notifyOnCompletion },
      set: { on in
        pending.notifyOnCompletion = on
        Task {
          if on, !(await notifications.requestPermission()) {
            if pending.notifyOnCompletion == on { pending.notifyOnCompletion = nil }
            return
          }
          await settings.save(PreferencesPatch(notifyOnCompletion: on))
          if pending.notifyOnCompletion == on { pending.notifyOnCompletion = nil }
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
        Text(theme.hint).font(.caption).foregroundStyle(.themeSecondary)
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
