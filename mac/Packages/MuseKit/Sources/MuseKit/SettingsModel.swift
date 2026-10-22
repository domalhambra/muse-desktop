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
  /// Why the last bridge read failed, quiet or not, shown as a lasting row while the Bridges pane
  /// polls. Cleared by the next read that succeeds.
  public private(set) var bridgeError: String?
  /// Why mMac could not read the bridge token from the Keychain at launch. The backend then
  /// started without one. The Bridges pane shows it as a lasting warning until the backend holds
  /// a new token.
  public private(set) var tokenError: String?
  /// A token made in this window, shown once.
  public private(set) var newToken: String?
  /// The backend's token when the Keychain refused it, with the Keychain's refusal. Unlike
  /// `newToken` it outlasts the Bridges pane, so Copy token never falls back to the older token
  /// in the Keychain, which the backend no longer accepts. Cleared when a new token is saved.
  private var unsaved: (token: String, error: String)?
  /// The backend's new token while the store saves it, which can wait behind a Keychain password
  /// prompt. The store still holds the older token meanwhile, so Copy token must not read it.
  private var saving: String?
  /// True while a new token is being made. The view disables Make token meanwhile.
  public private(set) var makingToken = false
  public var errorMessage: String?
  private var listSequence = 0
  /// Numbers each bridge read, so a read that ends after a newer one started is dropped.
  private var bridgeSequence = 0
  /// Counts the MCP changes made, so a reconnect knows whether one came in while it ran.
  private var changes = 0
  /// Numbers each Copy token, so a store read that ends after a newer copy started is dropped.
  private var copySequence = 0
  /// Counts the tokens made, so a store read that a new token overtook reads again.
  private var tokensMade = 0

  public init(workspace: Workspace, tokens: any BridgeTokenStore, tokenError: String? = nil) {
    self.workspace = workspace
    self.tokens = tokens
    self.tokenError = tokenError
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

  /// Reads the bridge status. A failure shows in `errorMessage`, or with `quietly` only in
  /// `bridgeError`, so the Bridges pane's poll raises no alert every time it runs. A read that
  /// ends after a newer one started is dropped, so a poll never shows an older status than a save.
  public func refreshBridge(quietly: Bool = false) async {
    bridgeSequence += 1
    let sequence = bridgeSequence
    do {
      let status = try await client.bridgeStatus()
      guard sequence == bridgeSequence else { return }
      bridge = status
      bridgeError = nil
    } catch {
      guard sequence == bridgeSequence else { return }
      bridgeError = error.localizedDescription
      if !quietly { errorMessage = error.localizedDescription }
    }
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
  /// one is refused. With `quietly`, for an edit that ended because the Bridges pane or the
  /// Settings window went away, a refusal only resets the field: an alert then would show later,
  /// over whatever pane is open, about a field no longer there.
  public func savePort(_ text: String, quietly: Bool = false) async -> String {
    guard let port = SettingsRules.port(text) else {
      if !quietly { errorMessage = SettingsRules.portError }
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
    tokensMade += 1
    // The backend holds a new token now, so a failed read at launch no longer matters, whatever
    // the Keychain does with it. A refusal shows as `unsavedTokenWarning` instead.
    tokenError = nil
    saving = token
    var keychainError: String?
    do {
      try await Self.write(token, to: tokens)
      saving = nil
      unsaved = nil
    } catch {
      saving = nil
      let message = "mMac could not save the token in the Keychain: \(error.localizedDescription)"
      keychainError = message
      unsaved = (token, message)
      errorMessage = message
    }
    await refreshBridge()
    // A failed status read must not hide that the token was not saved.
    if let keychainError { errorMessage = keychainError }
  }

  /// Why the token in use is not in the Keychain, shown as a lasting warning while it is not.
  public var unsavedTokenWarning: String? {
    guard let error = unsaved?.error else { return nil }
    let sentence = error.hasSuffix(".") ? error : error + "."
    return "\(sentence) Copy token copies the token in use until mMac or its backend restarts. Agents using it then lose access. Make a new token to try saving again."
  }

  /// Forgets the token shown once. The Bridges pane calls it when it closes. A token the Keychain
  /// refused stays for Copy token.
  public func clearNewToken() { newToken = nil }

  /// The token for Copy token: the one the Keychain refused, which is the only valid one then, or
  /// the one being saved, or the one on screen, or else the saved one, read off the main actor. Returns nil when a newer
  /// Copy token started while the store was read, so the clipboard ends with the newest result.
  public func copyToken() async throws -> String? {
    copySequence += 1
    let sequence = copySequence
    while true {
      if let token = unsaved?.token ?? saving ?? newToken { return token }
      let made = tokensMade
      let read: String?
      do {
        read = try await Self.read(from: tokens)
      } catch {
        guard sequence == copySequence else { return nil }
        // A token made during the read is in memory: look again rather than fail.
        guard made == tokensMade else { continue }
        throw error
      }
      guard sequence == copySequence else { return nil }
      // A token made during the read replaced the one read: look again.
      guard made == tokensMade else { continue }
      guard let read, !read.isEmpty else { throw WorkspaceError("Make a token first.") }
      return read
    }
  }

  /// The store's calls run off the main actor. mMac is signed ad hoc, so the Keychain can ask
  /// for the login password, and Settings must keep drawing meanwhile.
  private nonisolated static func read(from tokens: any BridgeTokenStore) async throws -> String? {
    try await Task.detached { try tokens.read() }.value
  }

  private nonisolated static func write(_ token: String, to tokens: any BridgeTokenStore) async throws {
    try await Task.detached { try tokens.write(token) }.value
  }
}
