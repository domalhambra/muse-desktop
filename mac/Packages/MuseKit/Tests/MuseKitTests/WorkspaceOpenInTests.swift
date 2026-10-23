import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

@MainActor @Test func theInspectorOpensTheProjectInTerminalAndMuseCode() async throws {
  let (workspace, backend) = await makeWorkspace { _, _, id in [reply(id, "null")] }
  await workspace.openProjectInTerminal()
  await workspace.openProjectInMuseCode()
  #expect(requests(backend) == [["terminal", ["/p"]], ["cli-terminal", ["/p"]]])
  #expect(workspace.errorMessage == nil)
}

@MainActor @Test func aTerminalErrorShowsInTheWindow() async throws {
  let (workspace, _) = await makeWorkspace { _, _, id in
    [failure(id, "Choose this project using Open project first.")]
  }
  await workspace.openProjectInMuseCode()
  #expect(workspace.errorMessage == "Choose this project using Open project first.")
}

@MainActor @Test func finderOpensTheProjectFolderAndReportsAFailure() async throws {
  let (workspace, _) = await makeWorkspace()
  var opened: [URL] = []
  workspace.revealProject { opened.append($0); return true }
  #expect(opened == [URL(fileURLWithPath: "/p", isDirectory: true)])
  #expect(workspace.errorMessage == nil)
  workspace.revealProject { _ in false }
  #expect(workspace.errorMessage == "mMac could not open /p.")
}

@MainActor @Test func withNoProjectNothingOpens() async throws {
  let (workspace, backend) = await makeWorkspace(preferences: Preferences())
  await workspace.openProjectInTerminal()
  await workspace.openProjectInMuseCode()
  var opened = 0
  workspace.revealProject { _ in opened += 1; return true }
  #expect(backend.messages.isEmpty)
  #expect(opened == 0)
}
