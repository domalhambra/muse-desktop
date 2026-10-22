import Foundation
import MuseBackend
import Synchronization
import MuseBackendTesting
import Testing
@testable import MuseKit

/// A store whose writes the Keychain refuses.
struct FailingTokenStore: BridgeTokenStore {
  func read() throws -> String? { nil }
  func write(_ token: String) throws { throw WorkspaceError("denied") }
}

/// A store that keeps an old token and refuses a new one.
struct StaleTokenStore: BridgeTokenStore {
  func read() throws -> String? { "stale" }
  func write(_ token: String) throws { throw WorkspaceError("denied") }
}

/// A store that refuses writes until `accept` is set, and notes whether any call ran on the main
/// thread.
final class RecordingTokenStore: BridgeTokenStore {
  private struct State {
    var token: String?
    var accept = false
    var onMain = false
    var calls = 0
  }
  private let state: Mutex<State>
  init(_ token: String? = nil) { state = Mutex(State(token: token)) }
  var accept: Bool {
    get { state.withLock { $0.accept } }
    set { state.withLock { $0.accept = newValue } }
  }
  var calledOnMainThread: Bool { state.withLock { $0.onMain } }
  var calls: Int { state.withLock { $0.calls } }
  func read() throws -> String? {
    let main = Thread.isMainThread
    return state.withLock {
      $0.calls += 1
      $0.onMain = $0.onMain || main
      return $0.token
    }
  }
  func write(_ token: String) throws {
    let main = Thread.isMainThread
    try state.withLock {
      $0.calls += 1
      $0.onMain = $0.onMain || main
      guard $0.accept else { throw WorkspaceError("denied") }
      $0.token = token
    }
  }
}

/// A store whose first read waits until `release()`.
final class GatedTokenStore: BridgeTokenStore {
  private let gate = DispatchSemaphore(value: 0)
  private let reads = Mutex(0)
  private let token: String
  init(_ token: String) { self.token = token }
  var started: Int { reads.withLock { $0 } }
  func release() { gate.signal() }
  func read() throws -> String? {
    let first = reads.withLock {
      $0 += 1
      return $0 == 1
    }
    if first { gate.wait() }
    return token
  }
  func write(_ token: String) throws {}
}

private let bridgeJSON =
  #"{"folder":"/d/bridge","files":{"enabled":false,"running":false},"mcp":{"enabled":false,"running":false,"url":"http://127.0.0.1:7735/mcp","hasToken":true},"activeJobs":0}"#

private func listJSON(_ names: String...) -> String {
  let servers = names.map { #"{"name":"\#($0)","transport":"stdio","enabled":true,"command":"npx"}"# }
  return #"{"file":"/c/settings.json","servers":[\#(servers.joined(separator: ","))]}"#
}

@MainActor @Test func addingAServerKeepsTheFormOnFailureAndNeedsAReconnect() async throws {
  let (workspace, backend) = await makeWorkspace { method, args, id in
    switch method {
    case "mcp-add":
      if case .object(let server)? = args.first, server["name"] == .string("bad name") {
        return [failure(id, "Use letters, numbers, - and _ for the server name.")]
      }
      return [reply(id, "null")]
    case "mcp-list": return [reply(id, listJSON("good"))]
    default: return []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  // A refusal shows under the form and leaves another action's error as it was.
  settings.errorMessage = "earlier"
  var form = McpForm()
  form.name = "bad name"
  form.command = "npx"
  #expect(await settings.addServer(form) == "Use letters, numbers, - and _ for the server name.")
  #expect(settings.errorMessage == "earlier")
  settings.errorMessage = nil
  #expect(!settings.needsReconnect)
  #expect(!requests(backend).contains { $0.first == .string("mcp-list") })
  form.name = "good"
  #expect(await settings.addServer(form) == nil)
  #expect(settings.needsReconnect)
  #expect(requests(backend).contains { $0.first == .string("mcp-list") })
  #expect(settings.servers.map(\.name) == ["good"])
  #expect(settings.settingsFile == "/c/settings.json")
}

@MainActor @Test func aFormThatCannotBeReadSendsNothing() async throws {
  let (workspace, backend) = await makeWorkspace()
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  var form = McpForm()
  form.name = "x"
  form.command = "npx"
  form.environment = "NOEQUALS"
  #expect(await settings.addServer(form) == "Write each line as name=value: NOEQUALS")
  #expect(settings.errorMessage == nil)
  #expect(!settings.needsReconnect)
  #expect(requests(backend).isEmpty)
}

@MainActor @Test func turningOnRemovingAndSigningInSendTheirRequests() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "mcp-enabled", "mcp-remove", "mcp-login": [reply(id, "null")]
    case "mcp-list": [reply(id, listJSON())]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.signIn("docs")
  #expect(!settings.needsReconnect)
  await settings.setEnabled("docs", false)
  #expect(settings.needsReconnect)
  await settings.remove("docs")
  #expect(
    requests(backend) == [
      ["mcp-login", ["docs", false]],
      ["mcp-enabled", ["docs", false]], ["mcp-list", []],
      ["mcp-remove", ["docs"]], ["mcp-list", []],
    ])
  #expect(settings.errorMessage == nil)
}

@MainActor @Test func aNewTokenGoesToTheStoreAndShowsOnce() async throws {
  let tokens = MemoryTokenStore()
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "bridge-token": return [reply(id, #""new-token""#)]
    case "bridge-status": return [reply(id, bridgeJSON)]
    default: return []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: tokens)
  await settings.makeToken()
  #expect(try tokens.read() == "new-token")
  #expect(settings.newToken == "new-token")
  #expect(settings.bridge?.mcp.hasToken == true)
  #expect(try await settings.copyToken() == "new-token")
  #expect(!settings.makingToken)
}

@MainActor @Test func aTokenTheKeychainRefusesStillShows() async {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "bridge-token": [reply(id, #""t""#)]
    case "bridge-status": [reply(id, bridgeJSON)]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: FailingTokenStore())
  await settings.makeToken()
  #expect(settings.newToken == "t")
  #expect(settings.errorMessage == "mMac could not save the token in the Keychain: denied")
}

@MainActor @Test func aSecondTokenRequestWhileOneRunsDoesNothing() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "bridge-status" ? [reply(id, bridgeJSON)] : []
  }
  let tokens = MemoryTokenStore()
  let settings = SettingsModel(workspace: workspace, tokens: tokens)
  let first = Task { await settings.makeToken() }
  try await eventually { backend.messages.contains { $0["method"] == "bridge-token" } }
  #expect(settings.makingToken)
  await settings.makeToken()
  #expect(requests(backend).filter { $0.first == "bridge-token" }.count == 1)
  guard case .number(let id)? = backend.messages.first(where: { $0["method"] == "bridge-token" })?["id"] else {
    Issue.record("No bridge-token request")
    return
  }
  backend.push(reply(Int(id), #""only""#))
  await first.value
  #expect(!settings.makingToken)
  #expect(settings.newToken == "only")
  #expect(try tokens.read() == "only")
  #expect(requests(backend).filter { $0.first == "bridge-token" }.count == 1)
}

@MainActor @Test func copyingWithNoTokenSaysSo() async {
  let (workspace, _) = await makeWorkspace()
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await #expect(throws: WorkspaceError("Make a token first.")) { try await settings.copyToken() }
  let empty = SettingsModel(workspace: workspace, tokens: MemoryTokenStore(""))
  await #expect(throws: WorkspaceError("Make a token first.")) { try await empty.copyToken() }
}

@MainActor @Test func copyingWithNoNewTokenReadsTheStore() async throws {
  let (workspace, _) = await makeWorkspace()
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore("saved"))
  #expect(try await settings.copyToken() == "saved")
}

@MainActor @Test func copyingAfterTheKeychainRefusedGivesTheTokenOnScreen() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "bridge-token": [reply(id, #""shown""#)]
    case "bridge-status": [reply(id, bridgeJSON)]
    default: []
    }
  }
  // The store still holds an older token, which the backend no longer accepts.
  let settings = SettingsModel(workspace: workspace, tokens: StaleTokenStore())
  await settings.makeToken()
  #expect(try await settings.copyToken() == "shown")
}

@MainActor @Test func aKeychainErrorOutlastsAFailedBridgeRead() async {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "bridge-token": [reply(id, #""t""#)]
    case "bridge-status": [failure(id, "The bridge is not running.")]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: FailingTokenStore())
  await settings.makeToken()
  #expect(settings.newToken == "t")
  #expect(settings.errorMessage == "mMac could not save the token in the Keychain: denied")
}

@MainActor @Test func aBadPortIsRefusedAndTheFieldResets() async {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "preferences": [reply(id, #"{"recentProjects":["/p"],"bridgeMcpPort":7736}"#)]
    case "bridge-status": [reply(id, bridgeJSON)]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  #expect(await settings.savePort("80") == "7735")
  #expect(settings.errorMessage == SettingsRules.portError)
  #expect(requests(backend).isEmpty)
  settings.errorMessage = nil
  #expect(await settings.savePort(" 7736 ") == "7736")
  #expect(workspace.preferences.bridgeMcpPort == 7736)
  #expect(requests(backend) == [["preferences", [["bridgeMcpPort": 7736]]], ["bridge-status", []]])
  #expect(settings.bridge?.folder == "/d/bridge")
  #expect(settings.errorMessage == nil)
}

@MainActor @Test func aPortRefusedQuietlyOnlyResetsTheField() async {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "preferences": [reply(id, #"{"recentProjects":["/p"],"bridgeMcpPort":7736}"#)]
    case "bridge-status": [reply(id, bridgeJSON)]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  #expect(await settings.savePort("80", quietly: true) == "7735")
  #expect(settings.errorMessage == nil)
  #expect(requests(backend).isEmpty)
  // A port it takes is still saved.
  #expect(await settings.savePort("7736", quietly: true) == "7736")
  #expect(workspace.preferences.bridgeMcpPort == 7736)
  #expect(settings.errorMessage == nil)
}

@MainActor @Test func aPreferenceThatIsNotABridgeDoesNotReadTheBridge() async {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "preferences" ? [reply(id, #"{"recentProjects":["/p"],"theme":"moonlight"}"#)] : []
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.save(PreferencesPatch(theme: "moonlight"))
  #expect(workspace.preferences.theme == "moonlight")
  #expect(requests(backend) == [["preferences", [["theme": "moonlight"]]]])
}

@MainActor @Test func theWorkspaceShowsAFailedSave() async {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "preferences" ? [failure(id, "The preferences file is read-only.")] : []
  }
  #expect(await workspace.save(PreferencesPatch(theme: "moonlight")) == false)
  #expect(workspace.errorMessage == "The preferences file is read-only.")
  #expect(workspace.preferences.theme == "muse")
}

@MainActor @Test func aFailedSaveShowsItsErrorAndKeepsThePreferences() async {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "preferences" ? [failure(id, "The preferences file is read-only.")] : []
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  #expect(await settings.save(PreferencesPatch(bridgeMcpEnabled: true)) == false)
  #expect(settings.errorMessage == "The preferences file is read-only.")
  #expect(workspace.errorMessage == nil)
  #expect(!workspace.preferences.bridgeMcpEnabled)
  // No bridge read after a failed save.
  #expect(!requests(backend).contains { $0.first == "bridge-status" })
}

@MainActor @Test func aMuseCodePathIsTrimmedSavedThenReconnects() async {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "preferences": [reply(id, #"{"cliPath":"/opt/muse","recentProjects":["/p"]}"#)]
    case "connect": [reply(id, #"{"state":"ready","version":"1.4.11"}"#)]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.setCLIPath("  /opt/muse \n")
  #expect(workspace.preferences.cliPath == "/opt/muse")
  #expect(requests(backend) == [["preferences", [["cliPath": "/opt/muse"]]], ["connect", []]])
  #expect(settings.errorMessage == nil)
}

@MainActor @Test func aMuseCodePathThatFailsToSaveDoesNotReconnect() async {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "preferences" ? [failure(id, "denied")] : []
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.setCLIPath("/opt/muse")
  #expect(settings.errorMessage == "denied")
  #expect(workspace.errorMessage == nil)
  #expect(requests(backend) == [["preferences", [["cliPath": "/opt/muse"]]]])
}

@MainActor @Test func aMuseCodePathSavedButNotConnectedShowsInSettings() async {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "preferences": [reply(id, #"{"cliPath":"/opt/muse","recentProjects":["/p"]}"#)]
    case "connect": [failure(id, "Muse Code did not start.")]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.setCLIPath("/opt/muse")
  #expect(workspace.preferences.cliPath == "/opt/muse")
  #expect(settings.errorMessage == "Muse Code did not start.")
  #expect(workspace.errorMessage == nil)
  #expect(requests(backend) == [["preferences", [["cliPath": "/opt/muse"]]], ["connect", []]])
}

@MainActor @Test func aFailedReconnectKeepsTheNoticeAndShowsInSettings() async {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "mcp-enabled": [reply(id, "null")]
    case "mcp-list": [reply(id, listJSON("docs"))]
    case "connect": [failure(id, "Muse Code is not installed.")]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.setEnabled("docs", true)
  await settings.reconnect()
  #expect(settings.needsReconnect)
  #expect(settings.errorMessage == "Muse Code is not installed.")
  #expect(workspace.errorMessage == nil)
}

@MainActor @Test func aChangeDuringAReconnectKeepsTheNotice() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "mcp-enabled": [reply(id, "null")]
    case "mcp-list": [reply(id, listJSON("docs"))]
    default: []  // connect waits for the reply pushed below
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.setEnabled("docs", true)
  let reconnecting = Task { await settings.reconnect() }
  try await eventually { backend.messages.contains { $0["method"] == "connect" } }
  await settings.setEnabled("docs", false)
  guard case .number(let id)? = backend.messages.first(where: { $0["method"] == "connect" })?["id"] else {
    Issue.record("No connect request")
    return
  }
  backend.push(reply(Int(id), #"{"state":"ready","version":"1.4.11"}"#))
  await reconnecting.value
  #expect(settings.needsReconnect)
  #expect(settings.errorMessage == nil)
}

@MainActor @Test func theWorkspaceReconnectSaysWhetherItConnected() async {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "connect" ? [failure(id, "no")] : []
  }
  #expect(await workspace.reconnect() == false)
  #expect(workspace.errorMessage == "no")
}

@MainActor @Test func reconnectClearsTheNotice() async {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    switch method {
    case "mcp-enabled": [reply(id, "null")]
    case "mcp-list": [reply(id, listJSON("docs"))]
    case "connect": [reply(id, #"{"state":"ready","version":"1.4.11"}"#)]
    default: []
    }
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.setEnabled("docs", true)
  #expect(settings.needsReconnect)
  await settings.reconnect()
  #expect(!settings.needsReconnect)
  #expect(requests(backend).last == ["connect", []])
}

@MainActor @Test func anErrorFromAnyCallShows() async {
  let (workspace, _) = await makeWorkspace { method, _, id in
    [failure(id, "\(method) failed")]
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.loadServers()
  #expect(settings.errorMessage == "mcp-list failed")
  await settings.refreshBridge()
  #expect(settings.errorMessage == "bridge-status failed")
  await settings.signIn("docs")
  #expect(settings.errorMessage == "mcp-login failed")
  await settings.remove("docs")
  #expect(settings.errorMessage == "mcp-remove failed")
  await settings.makeToken()
  #expect(settings.errorMessage == "bridge-token failed")
  #expect(settings.newToken == nil)
  #expect(!settings.makingToken)
}

@MainActor @Test func anOlderListReadThatEndsLateIsDropped() async throws {
  let lists = Counter()
  let (workspace, backend) = await makeWorkspace { method, _, id in
    // The first read waits; the second answers at once.
    guard method == "mcp-list", lists.next() == 2 else { return [] }
    return [reply(id, listJSON("second"))]
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  let first = Task { await settings.loadServers() }
  try await eventually { backend.messages.contains { $0["method"] == "mcp-list" } }
  await settings.loadServers()
  #expect(settings.servers.map(\.name) == ["second"])
  guard case .number(let lateId)? = backend.messages.first(where: { $0["method"] == "mcp-list" })?["id"] else {
    Issue.record("No first mcp-list request")
    return
  }
  backend.push(reply(Int(lateId), listJSON("first")))
  await first.value
  #expect(settings.servers.map(\.name) == ["second"])
}

@MainActor @Test func aQuietBridgeReadThatFailsShowsARowAndNoAlert() async {
  let reads = Counter()
  let (workspace, _) = await makeWorkspace { method, _, id in
    guard method == "bridge-status" else { return [] }
    // The first two reads fail; the third succeeds.
    return reads.next() <= 2 ? [failure(id, "The backend is busy.")] : [reply(id, bridgeJSON)]
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  await settings.refreshBridge(quietly: true)
  await settings.refreshBridge(quietly: true)
  #expect(settings.errorMessage == nil)
  #expect(settings.bridgeError == "The backend is busy.")
  await settings.refreshBridge(quietly: true)
  #expect(settings.bridgeError == nil)
  #expect(settings.bridge?.folder == "/d/bridge")
  #expect(settings.errorMessage == nil)
}

@MainActor @Test func anOlderBridgeReadThatEndsLateIsDropped() async throws {
  let reads = Counter()
  let (workspace, backend) = await makeWorkspace { method, _, id in
    // The first read waits; the second answers at once.
    guard method == "bridge-status", reads.next() == 2 else { return [] }
    return [reply(id, bridgeJSON)]
  }
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore())
  let first = Task { await settings.refreshBridge(quietly: true) }
  try await eventually { backend.messages.contains { $0["method"] == "bridge-status" } }
  await settings.refreshBridge()
  #expect(settings.bridge?.mcp.hasToken == true)
  guard case .number(let lateId)? = backend.messages.first(where: { $0["method"] == "bridge-status" })?["id"] else {
    Issue.record("No first bridge-status request")
    return
  }
  backend.push(failure(Int(lateId), "late"))
  await first.value
  #expect(settings.bridgeError == nil)
  #expect(settings.bridge?.mcp.hasToken == true)
}

@MainActor @Test func aKeychainReadErrorLastsUntilATokenIsSaved() async {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "bridge-token": [reply(id, #""t""#)]
    case "bridge-status": [reply(id, bridgeJSON)]
    default: []
    }
  }
  let message = "mMac could not read the bridge token from the Keychain: denied"
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore(), tokenError: message)
  #expect(settings.tokenError == message)
  // Shown as a lasting row, never as the Settings window's alert.
  #expect(settings.errorMessage == nil)
  await settings.refreshBridge()
  #expect(settings.tokenError == message)
  await settings.makeToken()
  #expect(settings.tokenError == nil)
  // A Keychain that refuses the new token keeps the warning.
  let refused = SettingsModel(workspace: workspace, tokens: FailingTokenStore(), tokenError: message)
  await refused.makeToken()
  #expect(refused.tokenError == message)
}

@MainActor @Test func clearingTheNewTokenHidesIt() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "bridge-token": [reply(id, #""once""#)]
    case "bridge-status": [reply(id, bridgeJSON)]
    default: []
    }
  }
  let tokens = MemoryTokenStore()
  let settings = SettingsModel(workspace: workspace, tokens: tokens)
  await settings.makeToken()
  #expect(settings.newToken == "once")
  settings.clearNewToken()
  #expect(settings.newToken == nil)
  // Copy token still gives the saved token.
  #expect(try await settings.copyToken() == "once")
}

@MainActor @Test func anUnsavedTokenOutlastsThePaneAndCopiesFirst() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "bridge-token": [reply(id, #""unsaved-\#(id)""#)]
    case "bridge-status": [reply(id, bridgeJSON)]
    default: []
    }
  }
  // The Keychain refuses the new token and still holds an older one the backend no longer accepts.
  let tokens = RecordingTokenStore("stale")
  let settings = SettingsModel(workspace: workspace, tokens: tokens)
  #expect(settings.unsavedTokenWarning == nil)
  await settings.makeToken()
  guard let shown = settings.newToken else {
    Issue.record("No token shown")
    return
  }
  // The pane closes, which hides the shown-once token. Copy token still gives the one in use.
  settings.clearNewToken()
  #expect(settings.newToken == nil)
  #expect(try await settings.copyToken() == shown)
  #expect(
    settings.unsavedTokenWarning
      == "mMac could not save the token in the Keychain: denied. Copy token copies the token in use until mMac quits. Make a new token to save one."
  )
  // A token the Keychain saves ends the warning, and Copy token reads the store again.
  tokens.accept = true
  await settings.makeToken()
  let saved = try #require(settings.newToken)
  #expect(saved != shown)
  settings.clearNewToken()
  #expect(settings.unsavedTokenWarning == nil)
  #expect(try await settings.copyToken() == saved)
}

@MainActor @Test func theTokenStoreIsNeverCalledOnTheMainThread() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    switch method {
    case "bridge-token": [reply(id, #""t""#)]
    case "bridge-status": [reply(id, bridgeJSON)]
    default: []
    }
  }
  let tokens = RecordingTokenStore("saved")
  tokens.accept = true
  let settings = SettingsModel(workspace: workspace, tokens: tokens)
  #expect(try await settings.copyToken() == "saved")
  await settings.makeToken()
  settings.clearNewToken()
  #expect(try await settings.copyToken() == "t")
  #expect(tokens.calls == 3)
  #expect(!tokens.calledOnMainThread)
}

@MainActor @Test(.timeLimit(.minutes(1))) func anOlderCopyThatEndsLastIsDropped() async throws {
  let (workspace, _) = await makeWorkspace()
  let tokens = GatedTokenStore("saved")
  let settings = SettingsModel(workspace: workspace, tokens: tokens)
  let first = Task { try await settings.copyToken() }
  try await eventually { tokens.started == 1 }
  // The newer copy finishes first; the older one, released after it, gives nothing.
  #expect(try await settings.copyToken() == "saved")
  tokens.release()
  #expect(try await first.value == nil)
}
