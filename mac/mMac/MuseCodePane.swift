import AppKit
import MuseBackend
import MuseKit
import SwiftUI

/// Electron's Muse Code tab: the connection, a custom path, and the installation guide. Every
/// action goes through `SettingsModel`, so its errors show on the Settings window.
struct MuseCodePane: View {
  let settings: SettingsModel
  @State private var path = ""

  private var workspace: Workspace { settings.workspace }
  private var status: ConnectionStatus { workspace.status }

  var body: some View {
    Form {
      Section("Muse Code connection") {
        HStack {
          VStack(alignment: .leading) {
            Text(stateText).font(.headline)
            // As Electron's `status.version ? … : status.message`.
            Text(status.version.map { "Version \($0)" } ?? status.message ?? "")
              .foregroundStyle(.themeSecondary)
          }
          Spacer()
          Button {
            Task { await settings.reconnect() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("Reconnect to Muse Code")
          .help("Reconnect to Muse Code")
        }
        if let used = status.path, !used.isEmpty {
          LabeledContent("Path", value: used).textSelection(.enabled)
        }
        if let warning = status.fingerprintWarning, !warning.isEmpty {
          Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
      }
      Section {
        TextField("Custom executable path", text: $path, prompt: Text("Automatic detection (recommended)"))
        HStack {
          Button("Browse…") {
            Task {
              guard let path = await AppController.chooseCLIPath() else { return }
              await settings.setCLIPath(path)
            }
          }
          Spacer()
          if !workspace.preferences.cliPath.isEmpty {
            Button("Use automatic detection") { Task { await settings.setCLIPath("") } }
          }
          Button("Save & reconnect") { Task { await settings.setCLIPath(path) } }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.primary)
        }
      } footer: {
        Text("Leave empty to find Muse through your login shell and standard installation locations.")
          .foregroundStyle(.themeSecondary)
      }
      Section("New to Muse Code?") {
        Text(
          "Install Muse Code using the official instructions, then run `muse login` in Terminal. Your credentials stay with the CLI."
        )
        .foregroundStyle(.themeSecondary)
        Button("Open installation guide") {
          NSWorkspace.shared.open(URL(string: "https://dev.meta.ai/docs/muse-code")!)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { path = workspace.preferences.cliPath }
    // A save from any button, or from the banner, shows the saved path.
    .onChange(of: workspace.preferences.cliPath) { _, saved in path = saved }
  }

  private var stateText: String {
    switch status.state {
    case "ready": "Muse Code is connected"
    case "connecting": "Connecting to Muse Code…"
    default: "Muse Code is disconnected"
    }
  }
}
