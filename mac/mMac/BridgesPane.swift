import AppKit
import MuseBackend
import MuseKit
import SwiftUI

/// Electron's Bridges tab. Every action goes through `SettingsModel`, so its errors show on the
/// Settings window. The token lives in the login Keychain, through `BridgeTokenStore`.
struct BridgesPane: View {
  let settings: SettingsModel
  @State private var port = ""
  /// The text last sent to `savePort`. Return ends editing, and so does the focus loss after it;
  /// the second end sends nothing while the field still shows the same text.
  @State private var committedPort: String?

  private var preferences: Preferences { settings.workspace.preferences }
  private var status: BridgeStatus? { settings.bridge }
  private var hasToken: Bool { status?.mcp.hasToken == true }

  var body: some View {
    Form {
      Section {
        Text(
          "Let another agent, such as the Muse app, ask Muse Code to work in projects you have opened and trusted here. Every job appears in this window with its approvals."
        )
        .foregroundStyle(.themeSecondary)
        if let error = settings.bridgeError {
          Label("mMac could not read the bridge status: \(error)", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      } header: {
        Text("Bridges")
      }
      Section {
        Toggle(isOn: binding(preferences.bridgeFilesEnabled) { PreferencesPatch(bridgeFilesEnabled: $0) }) {
          Text("Folder bridge")
          Text("Requests are Markdown files in a folder. \(state(status?.files.error, running: status?.files.running))")
            .foregroundStyle(.themeSecondary)
        }
        .toggleStyle(.switch)
        .accessibilityIdentifier("bridge-files-toggle")
        if let folder = status?.folder {
          Text(folder)
            .font(.caption.monospaced())
            .foregroundStyle(.themeSecondary)
            .textSelection(.enabled)
        }
        // As Electron: the button and its hint always show. mMac opens the folder itself, so the
        // button waits until the bridge status has named it.
        VStack(alignment: .leading, spacing: 6) {
          Button {
            if let folder = status?.folder { openFolder(folder) }
          } label: {
            Label("Open bridge folder", systemImage: "folder")
          }
          .disabled(status?.folder == nil)
          Text("Give the README.md in that folder to the other agent as its instructions.")
            .font(.caption)
            .foregroundStyle(.themeSecondary)
        }
      }
      Section {
        if let error = settings.tokenError {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        if let warning = settings.unsavedTokenWarning {
          Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        Toggle(isOn: binding(preferences.bridgeMcpEnabled) { PreferencesPatch(bridgeMcpEnabled: $0) }) {
          Text("MCP bridge")
          Text(
            "A local MCP server for agents that speak MCP. \(hasToken ? state(status?.mcp.error, running: status?.mcp.running) : "Make a token first.")"
          )
          .foregroundStyle(.themeSecondary)
        }
        .toggleStyle(.switch)
        // As Electron: with no token the bridge cannot start, but a bridge left on can be turned off.
        .disabled(!hasToken && !preferences.bridgeMcpEnabled)
        .accessibilityIdentifier("bridge-mcp-toggle")
        if let url = status?.mcp.url {
          Text(url)
            .font(.caption.monospaced())
            .foregroundStyle(.themeSecondary)
            .textSelection(.enabled)
        }
        LabeledContent("Port") {
          PlainTextField(
            accessibilityLabel: "Port", text: $port, identifier: "bridge-port", onEndEditing: commitPort
          )
          .frame(width: 90)
        }
        if let token = settings.newToken {
          VStack(alignment: .leading, spacing: 4) {
            Text("New token, shown once").accessibilityHidden(true)
            Text(token)
              .font(.body.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 6)
              .padding(.vertical, 4)
              .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
              // Its own element, read as text, as the diff's lines are: see `DiffRow`.
              .accessibilityElement(children: .ignore)
              .accessibilityAddTraits(.isStaticText)
              .accessibilityLabel("New token, shown once")
              .accessibilityValue(token)
              .accessibilityIdentifier("bridge-new-token")
            Text("Send it as `Authorization: Bearer <token>`. Making a new token disconnects agents that use the old one.")
              .font(.caption)
              .foregroundStyle(.themeSecondary)
          }
        }
        HStack {
          Spacer()
          // As Electron: Copy token shows once there is a token.
          if hasToken || settings.newToken != nil {
            Button {
              Task { await copy() }
            } label: {
              Label("Copy token", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("bridge-copy-token")
          }
          Button {
            Task { await makeToken() }
          } label: {
            Label(hasToken ? "Make new token" : "Make token", systemImage: "key")
          }
          .disabled(settings.makingToken)
          .accessibilityIdentifier("bridge-make-token")
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { port = String(preferences.bridgeMcpPort) }
    // A save from Return or from focus loss shows the saved port.
    .onChange(of: preferences.bridgeMcpPort) { _, saved in port = String(saved) }
    // Typing, or a reset to the saved port, makes the next end of editing count again.
    .onChange(of: port) { _, text in if text != committedPort { committedPort = nil } }
    // Read now and every 2 seconds while the pane shows, so job counts and errors stay current.
    // Quietly: a failing read shows as a lasting row, never an alert every 2 seconds.
    // Restarts for another `SettingsModel`, as after a backend restart.
    .task(id: ObjectIdentifier(settings)) {
      while !Task.isCancelled {
        await settings.refreshBridge(quietly: true)
        try? await Task.sleep(for: .seconds(2))
      }
    }
    .onDisappear { settings.clearNewToken() }
  }

  /// Electron's `state`: the error, else Running or Off.
  private func state(_ error: String?, running: Bool?) -> String {
    if let error { return "Not running: \(error)" }
    return running == true ? "Running" : "Off"
  }

  /// A switch that shows the saved preference and saves a change. The save reads the bridge
  /// status again.
  private func binding(_ value: Bool, patch: @escaping (Bool) -> PreferencesPatch) -> Binding<Bool> {
    Binding(get: { value }, set: { next in Task { await settings.save(patch(next)) } })
  }

  /// Saves the typed port on Return and on focus loss. Return and the focus loss after it both
  /// end editing, so the same text is sent once, and an unchanged port not at all. A refused port
  /// resets the field and shows "Use a port between 1024 and 65535." on the Settings window, or,
  /// when editing ended because the pane or window went away, only resets the field.
  private func commitPort(shown: Bool) {
    let typed = port
    guard typed != String(preferences.bridgeMcpPort), typed != committedPort else { return }
    committedPort = typed
    Task { port = await settings.savePort(typed, quietly: !shown) }
  }

  /// Electron's `window.confirm`, as a sheet on the Settings window. Cancel is the default.
  private func makeToken() async {
    if hasToken {
      let choice = await SheetAlert.present(
        title: "Make a new token?", message: "Agents using the current token lose access.",
        buttons: ["Make new token", "Cancel"], preferringKey: true)
      guard choice == 0 else { return }
    }
    await settings.makeToken()
  }

  /// Copies the token. A copy that a newer one overtook while the Keychain was read copies
  /// nothing, so the clipboard ends with the newest result.
  private func copy() async {
    do {
      guard let token = try await settings.copyToken() else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(token, forType: .string)
    } catch {
      settings.errorMessage = error.localizedDescription
    }
  }

  /// As Electron's `bridge-reveal`: makes the folder, open to its owner only, then opens it.
  private func openFolder(_ folder: String) {
    do {
      try FileManager.default.createDirectory(
        atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      settings.errorMessage = error.localizedDescription
      return
    }
    if !NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true)) {
      settings.errorMessage = "mMac could not open \(folder)."
    }
  }
}
