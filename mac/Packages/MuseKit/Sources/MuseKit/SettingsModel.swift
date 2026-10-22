import Foundation
import MuseBackend
import Observation

/// The Settings window's state that is not a preference: the MCP servers and the bridges. Electron
/// keeps it in `McpSettings.tsx` and `BridgeSettings.tsx`. Preferences are the Workspace's, but every
/// action the Settings window starts goes through here and reports its error in `errorMessage`,
/// never the Workspace's, which the conversation window shows.
@MainActor @Observable
public final class SettingsModel {
  public let workspace: Workspace
  private let tokens: any BridgeTokenStore

  public private(set) var servers: [McpServer] = []
  public private(set) var settingsFile = ""
  /// After any MCP change: "Reconnect Muse Code to apply your changes."
  public private(set) var needsReconnect = false
  public private(set) var bridge: BridgeStatus?
  /// A token made in this window, shown once.
  public private(set) var newToken: String?
  /// True while a new token is being made. The view disables Make token meanwhile.
  public private(set) var makingToken = false
  public var errorMessage: String?
  private var listSequence = 0
  /// Counts the MCP changes made, so a reconnect knows whether one came in while it ran.
  private var changes = 0

  public init(workspace: Workspace, tokens: any BridgeTokenStore) {
    self.workspace = workspace
    self.tokens = tokens
  }

  private var client: BackendClient { workspace.client }

  // MARK: MCP servers

  /// Reads the servers. A read that finishes after a newer one started is dropped.
  public func loadServers() async {
    listSequence += 1
    let sequence = listSequence
    do {
      let list = try await client.mcpList()
      guard sequence == listSequence else { return }
      servers = list.servers
      settingsFile = list.file
    } catch {
      guard sequence == listSequence else { return }
      errorMessage = error.localizedDescription
    }
  }

  /// Returns nil when the server was added, so the view can close the form, or else the refusal,
  /// which the form shows under itself as typed. A refusal never goes to `errorMessage`, so the
  /// form never has to clear the Settings window's alert, nor another action's error with it.
  public func addServer(_ form: McpForm) async -> String? {
    do {
      try await client.mcpAdd(try form.input())
    } catch {
      return error.localizedDescription
    }
    await changed()
    return nil
  }

  public func setEnabled(_ name: String, _ enabled: Bool) async {
    await change { try await self.client.mcpSetEnabled(name, enabled) }
  }

  /// The view asks "Remove the MCP server <name>?" first.
  public func remove(_ name: String) async {
    await change { try await self.client.mcpRemove(name) }
  }

  /// Opens Terminal on `muse mcp login`. Nothing reports back, as in Electron.
  public func signIn(_ name: String) async {
    do { try await client.mcpLogin(name) } catch { errorMessage = error.localizedDescription }
  }

  /// Reconnects Muse Code. The notice stays when the reconnect fails, or when an MCP change was
  /// made while it ran, which it may not have picked up.
  public func reconnect() async {
    let before = changes
    guard await workspace.reconnect(reportingTo: { self.errorMessage = $0 }) else { return }
    if changes == before { needsReconnect = false }
  }

  private func change(_ work: () async throws -> Void) async {
    do {
      try await work()
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    await changed()
  }

  /// After an MCP change: the notice, and the list read again.
  private func changed() async {
    changes += 1
    needsReconnect = true
    await loadServers()
  }

  // MARK: Bridges

  public func refreshBridge() async {
    do { bridge = try await client.bridgeStatus() } catch { errorMessage = error.localizedDescription }
  }

  /// Saves a preference, and reads the bridge status again when it was a bridge field.
  @discardableResult
  public func save(_ patch: PreferencesPatch) async -> Bool {
    do {
      workspace.preferences = try await client.preferences(patch)
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    if patch.touchesBridges { await refreshBridge() }
    return true
  }

  /// Saves a custom Muse Code path (empty for automatic detection), then reconnects, as
  /// `Workspace.setCLIPath(_:)` does.
  public func setCLIPath(_ path: String) async {
    // Electron trims the field before saving it.
    guard await save(PreferencesPatch(cliPath: path.trimmingCharacters(in: .whitespacesAndNewlines))) else { return }
    await reconnect()
  }

  /// Saves the typed port. Returns the text the field should show: the saved port when the typed
  /// one is refused.
  public func savePort(_ text: String) async -> String {
    guard let port = SettingsRules.port(text) else {
      errorMessage = SettingsRules.portError
      return String(workspace.preferences.bridgeMcpPort)
    }
    await save(PreferencesPatch(bridgeMcpPort: port))
    return String(workspace.preferences.bridgeMcpPort)
  }

  /// Makes a new token, saves it in the store and shows it once. One request at a time: a call
  /// while one runs does nothing. The view asks "Make a new token? Agents using the current token
  /// lose access." first when one exists.
  public func makeToken() async {
    guard !makingToken else { return }
    makingToken = true
    defer { makingToken = false }
    let token: String
    do {
      token = try await client.bridgeNewToken()
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    newToken = token
    var keychainError: String?
    do {
      try tokens.write(token)
    } catch {
      keychainError = "mMac could not save the token in the Keychain: \(error.localizedDescription)"
      errorMessage = keychainError
    }
    await refreshBridge()
    // A failed status read must not hide that the token was not saved.
    if let keychainError { errorMessage = keychainError }
  }

  /// The token for Copy token: the one on screen, which is the only valid one when the Keychain
  /// refused it, or else the saved one.
  public func copyToken() throws -> String {
    if let newToken { return newToken }
    guard let token = try tokens.read(), !token.isEmpty else { throw WorkspaceError("Make a token first.") }
    return token
  }
}
