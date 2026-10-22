import Foundation
import MuseBackend
import Observation

/// The Settings window's state that is not a preference: the MCP servers and the bridges. Electron
/// keeps it in `McpSettings.tsx` and `BridgeSettings.tsx`. Preferences go through the Workspace.
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

  /// Returns true when the server was added, so the view can close the form. On false the view
  /// keeps the form as typed.
  public func addServer(_ form: McpForm) async -> Bool {
    await change { try await self.client.mcpAdd(try form.input()) }
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

  public func reconnect() async {
    await workspace.reconnect()
    needsReconnect = false
  }

  @discardableResult
  private func change(_ work: () async throws -> Void) async -> Bool {
    do {
      try await work()
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    needsReconnect = true
    await loadServers()
    return true
  }

  // MARK: Bridges

  public func refreshBridge() async {
    do { bridge = try await client.bridgeStatus() } catch { errorMessage = error.localizedDescription }
  }

  /// Saves a preference, and reads the bridge status again when it was a bridge field. A failed
  /// save shows in the Workspace's `errorMessage`.
  public func save(_ patch: PreferencesPatch) async {
    guard await workspace.save(patch) else { return }
    if patch.touchesBridges { await refreshBridge() }
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
    do {
      try tokens.write(token)
    } catch {
      errorMessage = "mMac could not save the token in the Keychain: \(error.localizedDescription)"
    }
    await refreshBridge()
  }

  /// The saved token, for Copy token.
  public func copyToken() throws -> String {
    guard let token = try tokens.read(), !token.isEmpty else { throw WorkspaceError("Make a token first.") }
    return token
  }
}
