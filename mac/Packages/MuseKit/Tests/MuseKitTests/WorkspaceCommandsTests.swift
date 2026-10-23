import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

private let modelsJSON = #"[{"modelId":"m1","displayLabel":"One","providerId":"p","isDefault":true,"isActive":true,"contextLimit":null},{"modelId":"m2","displayLabel":"Two","providerId":"p","isDefault":false,"isActive":true,"contextLimit":null}]"#

/// Answers `open` with s1 named "Named", `models` with m1 and m2, `compact` with `compact`,
/// `attachments` with one chip, and the rest with null, unless `extra` answers.
private func commandScript(
  compact: String = "started",
  _ extra: @escaping @Sendable (String, [JSONValue], Int) -> [String]? = { _, _, _ in nil }
) -> @Sendable (String, [JSONValue], Int) -> [String] {
  { method, args, id in
    if let answer = extra(method, args, id) { return answer }
    switch method {
    case "open": return [reply(id, viewJSON(sessionJSON("s1", name: "Named")))]
    case "models": return [reply(id, modelsJSON)]
    case "compact": return [reply(id, #"{"status":"\#(compact)"}"#)]
    case "attachments": return [reply(id, #"[{"id":"a1","name":"a.txt","kind":"text","size":3}]"#)]
    case "preferences": return [reply(id, #"{"recentProjects":["/p"],"reasoningEffort":"medium"}"#)]
    default: return [reply(id, "null")]
    }
  }
}

/// Puts `text` in the composer and runs it as a command.
@MainActor
private func runDraft(_ workspace: Workspace, _ text: String) async -> CommandEffect? {
  workspace.draft = text
  guard let command = ComposerCommand.parse(text) else {
    Issue.record("\(text) does not parse as a command")
    return nil
  }
  return await workspace.run(command)
}

@MainActor @Test func anUnknownCommandIsNotSentAndKeepsTheDraft() async throws {
  let (workspace, backend) = await makeWorkspace(script: commandScript())
  #expect(await runDraft(workspace, "/plugins list") == nil)
  #expect(
    workspace.errorMessage
      == "/plugins is not handled by Desktop. Use /help, or open Muse Code in the project inspector for CLI commands.")
  #expect(workspace.draft == "/plugins list")
  #expect(backend.messages.isEmpty)
}

@MainActor @Test func commandsRefuseChipsAfterTheNameCheck() async throws {
  let (workspace, _) = await makeWorkspace(script: commandScript())
  await workspace.open("s1")
  await workspace.attach([URL(fileURLWithPath: "/d/a.txt")])
  #expect(await runDraft(workspace, "/clear") == nil)
  #expect(workspace.errorMessage == "Send attachments with a message, or remove them before using a command.")
  #expect(workspace.view?.session.sessionId == "s1")
  #expect(workspace.draft == "/clear")
  // The name check comes first.
  #expect(await runDraft(workspace, "/plugins") == nil)
  #expect(workspace.errorMessage?.hasPrefix("/plugins is not handled by Desktop.") == true)
}

@MainActor @Test func clearAndNewStartANewConversationAndClearTheCommand() async throws {
  let (workspace, _) = await makeWorkspace(script: commandScript())
  await workspace.open("s1")
  #expect(await runDraft(workspace, "/clear") == nil)
  #expect(workspace.view == nil)
  #expect(workspace.drafts["s1"] == nil)
  await workspace.open("s1")
  // The argument is ignored.
  #expect(await runDraft(workspace, "/new please") == nil)
  #expect(workspace.view == nil)
  #expect(workspace.errorMessage == nil)
}

@MainActor @Test func helpAndSettingsAreForTheApp() async throws {
  let (workspace, backend) = await makeWorkspace(script: commandScript())
  #expect(await runDraft(workspace, "/help") == .help)
  #expect(workspace.draft == "")
  #expect(await runDraft(workspace, "/settings") == .settings)
  #expect(backend.messages.isEmpty)
}

@MainActor @Test func voiceTogglesCancelsExplainsOrRefuses() async throws {
  let (workspace, _) = await makeWorkspace(script: commandScript())
  #expect(await runDraft(workspace, "/voice") == .toggleVoice)
  #expect(await runDraft(workspace, "/voice cancel") == .cancelVoice)
  #expect(await runDraft(workspace, "/voice status") == nil)
  #expect(workspace.notice == "Use ⌥V to start or stop recording. Muse Code transcribes speech into your draft.")
  #expect(workspace.draft == "")
  // The argument is matched exactly, as Electron does.
  #expect(await runDraft(workspace, "/voice Cancel") == nil)
  #expect(workspace.errorMessage == "Use /voice to record, /voice cancel to discard, or /voice status for help.")
  #expect(workspace.draft == "/voice Cancel")
}

@MainActor @Test func modelOpensThePickerOrChoosesAnExactId() async throws {
  let (workspace, backend) = await makeWorkspace(script: commandScript())
  await workspace.loadModels()
  #expect(await runDraft(workspace, "/model") == .modelPicker)
  #expect(await runDraft(workspace, "/model M2") == nil)
  #expect(workspace.errorMessage == "Choose one of the models available in the Model menu.")
  workspace.errorMessage = nil
  // With no conversation open, the id is kept for the next one.
  #expect(await runDraft(workspace, "/model m2") == nil)
  #expect(workspace.modelId == "m2")
  #expect(!backend.messages.contains { $0["method"] == "set-model" })
  await workspace.open("s1")
  #expect(await runDraft(workspace, "/model m1") == nil)
  #expect(requests(backend).last == ["set-model", ["s1", "m1"]])
  #expect(workspace.modelId == "m1")
  #expect(workspace.errorMessage == nil)
}

@MainActor @Test func effortOpensThePickerOrSavesALevelInAnyCase() async throws {
  let (workspace, backend) = await makeWorkspace(script: commandScript())
  #expect(await runDraft(workspace, "/effort") == .effortPicker)
  #expect(await runDraft(workspace, "/effort MEDIUM") == nil)
  #expect(requests(backend).last == ["preferences", [["reasoningEffort": "medium"]]])
  #expect(workspace.effort == "medium")
  #expect(await runDraft(workspace, "/effort turbo") == nil)
  #expect(workspace.errorMessage == "Choose none, minimal, low, medium, high, xhigh, max, or ultra.")
}

@MainActor @Test func compactRenameAndStopNeedAConversation() async throws {
  let (workspace, backend) = await makeWorkspace(script: commandScript())
  for text in ["/compact", "/rename New", "/rename", "/stop"] {
    workspace.errorMessage = nil
    #expect(await runDraft(workspace, text) == nil)
    #expect(workspace.errorMessage == "Open a conversation before using this command.")
    #expect(workspace.draft == text)
  }
  #expect(backend.messages.isEmpty)
}

@MainActor @Test func compactShowsWhichNoticeTheStatusAsksFor() async throws {
  let (quiet, quietBackend) = await makeWorkspace(script: commandScript(compact: "noop"))
  await quiet.open("s1")
  #expect(await runDraft(quiet, "/compact") == nil)
  #expect(requests(quietBackend).last == ["compact", ["s1"]])
  #expect(quiet.notice == "There is no conversation history to compact yet.")
  let (busy, _) = await makeWorkspace(script: commandScript(compact: "started"))
  await busy.open("s1")
  #expect(await runDraft(busy, "/compact") == nil)
  #expect(busy.notice == "Muse is compacting this conversation.")
  #expect(busy.draft == "")
}

@MainActor @Test func stopCancelsAndRenameRenamesOrOpensTheSheet() async throws {
  let (workspace, backend) = await makeWorkspace(script: commandScript())
  await workspace.open("s1")
  #expect(await runDraft(workspace, "/stop") == nil)
  #expect(requests(backend).last == ["cancel", ["s1"]])
  #expect(await runDraft(workspace, "/rename   Trip plan ") == nil)
  #expect(requests(backend).last == ["rename", ["s1", "Trip plan"]])
  #expect(await runDraft(workspace, "/rename") == .renameSheet(title: "Named"))
}

@MainActor @Test func aFailingCommandKeepsItsDraftAndShowsTheError() async throws {
  let (workspace, _) = await makeWorkspace(script: commandScript { method, _, id in
    method == "compact" ? [failure(id, "Muse could not compact this conversation.")] : nil
  })
  await workspace.open("s1")
  #expect(await runDraft(workspace, "/compact") == nil)
  #expect(workspace.errorMessage == "Muse could not compact this conversation.")
  #expect(workspace.draft == "/compact")
  #expect(workspace.notice == nil)
  #expect(!workspace.submitting)
}

// The mention menu's listing.

private let rootFiles = #"[{"name":"src","path":"src","directory":true},{"name":"main.swift","path":"main.swift","directory":false}]"#
private let srcFiles = #"[{"name":"lib","path":"src/lib","directory":true},{"name":"app.swift","path":"src/app.swift","directory":false}]"#

private func filesScript() -> @Sendable (String, [JSONValue], Int) -> [String] {
  { method, args, id in
    guard method == "files" else { return [reply(id, "null")] }
    return [reply(id, args.last == "src" ? srcFiles : rootFiles)]
  }
}

private func fileRequests(_ backend: ScriptedBackend) -> [JSONValue] {
  requests(backend).filter { $0.first == "files" }.map { $0[1] }
}

@MainActor @Test func theMentionMenuListsAFolderOnceWhileTheFilterChanges() async throws {
  let (workspace, backend) = await makeWorkspace(script: filesScript())
  let menu = MentionMenu(workspace: workspace)
  await menu.update(draft: "see @")
  #expect(fileRequests(backend) == [["/p", ""]])
  #expect(menu.rows(for: "see @").map(\.path) == ["src", "main.swift"])
  await menu.update(draft: "see @ma")
  #expect(fileRequests(backend).count == 1)
  #expect(menu.rows(for: "see @ma").map(\.path) == ["main.swift"])
  await menu.update(draft: "see @src/")
  #expect(fileRequests(backend) == [["/p", ""], ["/p", "src"]])
  #expect(menu.rows(for: "see @src/").map(\.path) == ["src/lib", "src/app.swift"])
}

@MainActor @Test func escapeKeepsTheMenuClosedUntilTheFolderChanges() async throws {
  let (workspace, backend) = await makeWorkspace(script: filesScript())
  let menu = MentionMenu(workspace: workspace)
  await menu.update(draft: "@")
  menu.dismiss()
  #expect(menu.rows(for: "@").isEmpty)
  await menu.update(draft: "@m")
  #expect(menu.rows(for: "@m").isEmpty)
  #expect(fileRequests(backend).count == 1)
  // Ending the mention and starting a new one lists the folder again.
  await menu.update(draft: "@m ")
  await menu.update(draft: "@m @")
  #expect(fileRequests(backend).count == 2)
  #expect(menu.rows(for: "@m @").count == 2)
}

@MainActor @Test func withNoProjectThereAreNoMentions() async throws {
  let (workspace, backend) = await makeWorkspace(preferences: Preferences(), script: filesScript())
  let menu = MentionMenu(workspace: workspace)
  await menu.update(draft: "@")
  #expect(menu.rows(for: "@").isEmpty)
  #expect(fileRequests(backend).isEmpty)
}

@MainActor @Test func aFailedListingShowsNoRowsAndNoError() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "files" ? [failure(id, "This path is outside the selected project.")] : []
  }
  let menu = MentionMenu(workspace: workspace)
  await menu.update(draft: "@../")
  #expect(menu.rows(for: "@../").isEmpty)
  #expect(workspace.errorMessage == nil)
}
