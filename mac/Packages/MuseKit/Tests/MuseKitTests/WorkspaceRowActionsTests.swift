import Foundation
import MuseBackend
import MuseBackendTesting
import Testing
@testable import MuseKit

@MainActor @Test func aRowActionOpensItsConversationFirst() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "open" ? [reply(id, viewJSON(sessionJSON("s1")))] : [reply(id, "null")]
  }
  #expect(await workspace.ensureOpen("s1"))
  #expect(workspace.view?.session.sessionId == "s1")
  #expect(requests(backend) == [["open", ["s1"]]])
}

@MainActor @Test func aRowActionOnTheOpenConversationDoesNotReopenIt() async throws {
  let (workspace, backend) = await makeWorkspace { method, _, id in
    method == "open" ? [reply(id, viewJSON(sessionJSON("s1")))] : [reply(id, "null")]
  }
  await workspace.open("s1")
  #expect(await workspace.ensureOpen("s1"))
  #expect(requests(backend) == [["open", ["s1"]]])
}

@MainActor @Test func aRowActionWhoseOpenFailsDoesNothing() async throws {
  let (workspace, _) = await makeWorkspace { method, _, id in
    method == "open" ? [failure(id, "Muse could not open this conversation.")] : [reply(id, "null")]
  }
  #expect(await workspace.ensureOpen("s1") == false)
  #expect(workspace.view == nil)
  #expect(workspace.errorMessage == "Muse could not open this conversation.")
}
