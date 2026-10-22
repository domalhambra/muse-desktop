import Foundation
import MuseBackend
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
  var form = McpForm()
  form.name = "bad name"
  form.command = "npx"
  #expect(await settings.addServer(form) == false)
  #expect(settings.errorMessage == "Use letters, numbers, - and _ for the server name.")
  #expect(!settings.needsReconnect)
  #expect(!requests(backend).contains { $0.first == .string("mcp-list") })
  form.name = "good"
  #expect(await settings.addServer(form))
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
  #expect(await settings.addServer(form) == false)
  #expect(settings.errorMessage == "Write each line as name=value: NOEQUALS")
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
  #expect(try settings.copyToken() == "new-token")
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
  #expect(throws: WorkspaceError("Make a token first.")) { try settings.copyToken() }
  let empty = SettingsModel(workspace: workspace, tokens: MemoryTokenStore(""))
  #expect(throws: WorkspaceError("Make a token first.")) { try empty.copyToken() }
}

@MainActor @Test func copyingWithNoNewTokenReadsTheStore() async throws {
  let (workspace, _) = await makeWorkspace()
  let settings = SettingsModel(workspace: workspace, tokens: MemoryTokenStore("saved"))
  #expect(try settings.copyToken() == "saved")
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
  #expect(try settings.copyToken() == "shown")
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
