import Foundation
import MuseBackend
import MuseBackendTesting
import Synchronization
import Testing
@testable import MuseKit

func reply(_ id: Int, _ value: String) -> String { #"{"id":\#(id),"ok":true,"value":\#(value)}"# }

func failure(_ id: Int, _ message: String) -> String { #"{"id":\#(id),"ok":false,"error":"\#(message)"}"# }

func sessionJSON(
  _ id: String, root: String = "/p", status: String = "idle", updatedAt: String = "2026-10-21T10:00:00Z",
  name: String? = nil, modelId: String? = nil, title: String? = nil, firstUserPrompt: String? = nil
) -> String {
  let labels =
    (name.map { #","name":"\#($0)""# } ?? "") + (title.map { #","title":"\#($0)""# } ?? "")
    + (firstUserPrompt.map { #","firstUserPrompt":"\#($0)""# } ?? "")
  let model = modelId.map { #""\#($0)""# } ?? "null"
  return #"{"sessionId":"\#(id)","workspaceRoot":"\#(root)","createdAt":"2026-10-21T00:00:00Z","updatedAt":"\#(updatedAt)","status":"\#(status)","activeTurnId":null,"modelId":\#(model),"turnCount":0\#(labels)}"#
}

func viewJSON(_ session: String, approvals: String = "[]", questions: String = "[]") -> String {
  #"{"session":\#(session),"items":[],"approvals":\#(approvals),"questions":\#(questions)}"#
}

func decodeView(_ json: String) throws -> SessionView {
  try JSONDecoder().decode(SessionView.self, from: Data(json.utf8))
}

/// A Workspace over a scripted backend. `script` gets each request's method, arguments and id.
@MainActor
func makeWorkspace(
  preferences: Preferences = Preferences(recentProjects: ["/p"]),
  status: ConnectionStatus = ConnectionStatus(state: "ready", version: "1.4.11"),
  refreshDebounce: Duration = .milliseconds(10),
  drafts: [String: String] = [:],
  script: @escaping @Sendable (String, [JSONValue], Int) -> [String] = { _, _, _ in [] }
) async -> (Workspace, ScriptedBackend) {
  let backend = ScriptedBackend { message in
    guard case .string(let method)? = message["method"], case .number(let id)? = message["id"],
      case .array(let args)? = message["args"]
    else { return [] }
    return script(method, args, Int(id))
  }
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  let workspace = Workspace(
    client: client, started: Started(preferences: preferences, status: status),
    drafts: drafts, refreshDebounce: refreshDebounce)
  return (workspace, backend)
}

/// The requests the backend received, as method name and arguments.
func requests(_ backend: ScriptedBackend) -> [[JSONValue]] {
  backend.messages.compactMap { message in
    guard let method = message["method"] else { return nil }
    return [method, message["args"] ?? .null]
  }
}

/// Waits up to a second for `condition`.
@MainActor
func eventually(_ condition: () -> Bool) async throws {
  for _ in 0..<200 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for a condition")
}

/// A count that scripts and observation callbacks can share across threads.
final class Counter: Sendable {
  private let count = Mutex(0)
  /// Adds one and returns the new count.
  @discardableResult func next() -> Int { count.withLock { $0 += 1; return $0 } }
  var value: Int { count.withLock { $0 } }
}
