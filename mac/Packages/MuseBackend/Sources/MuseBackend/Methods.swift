import Foundation

/// How a message sent while Muse is working is handled.
public enum SendMode: String, Sendable, CaseIterable {
  /// Runs after the current turn.
  case queue
  /// Joins the current turn.
  case steer
}

// One typed call per headless method. Names and arguments match src/headless/backend.ts.
extension BackendClient {
  /// Checks that mMac and the backend speak one protocol. A mismatch stops the backend.
  public func hello() async throws -> Hello {
    try await call("hello", [.number(Double(backendProtocol))])
  }

  /// Reads mMac's preferences from `dataFolder` and connects to Muse.
  public func start(dataFolder: URL) async throws -> Started {
    try await call("start", [["dataFolder": .string(dataFolder.path)]])
  }

  /// Reconnects to Muse. The backend Asks first if a turn is running.
  public func connect() async throws -> ConnectionStatus { try await call("connect") }

  /// Saves preference fields and returns the whole set.
  public func preferences(_ patch: PreferencesPatch) async throws -> Preferences {
    try await call("preferences", [JSONValue(encoding: patch)])
  }

  /// Adds a folder chosen in mMac's panel to the recent projects. Returns its real path.
  public func addProject(_ folder: URL) async throws -> String {
    try await call("add-project", [.string(folder.path)])
  }

  /// One page of Muse history. Follow `nextCursor` for the rest.
  public func sessions(cursor: String? = nil) async throws -> SessionList {
    try await call("sessions", cursor.map { [.string($0)] } ?? [])
  }

  /// Starts a conversation. The backend may Ask to trust the project first.
  public func create(project: String, modelId: String? = nil) async throws -> SessionView {
    try await call("create", [.string(project)] + (modelId.map { [.string($0)] } ?? []))
  }

  /// Reads a conversation and subscribes to its updates, without claiming it.
  public func open(_ sessionId: String) async throws -> SessionView {
    try await call("open", [.string(sessionId)])
  }

  public func send(
    sessionId: String, text: String, effort: String = "high", mode: SendMode = .queue
  ) async throws {
    _ = try await request("send", [
      [
        "sessionId": .string(sessionId), "text": .string(text), "attachments": [],
        "effort": .string(effort), "mode": .string(mode.rawValue),
      ]
    ])
  }

  public func cancel(_ sessionId: String) async throws {
    _ = try await request("cancel", [.string(sessionId)])
  }

  public func rename(sessionId: String, name: String) async throws {
    _ = try await request("rename", [.string(sessionId), .string(name)])
  }

  /// The models Muse offers. With a session, the list can reflect that session.
  public func models(sessionId: String? = nil) async throws -> [MuseModel] {
    try await call("models", sessionId.map { [.string($0)] } ?? [])
  }

  public func setModel(sessionId: String, modelId: String) async throws {
    _ = try await request("set-model", [.string(sessionId), .string(modelId)])
  }

  public func approve(sessionId: String, approvalId: String, choiceId: String) async throws {
    _ = try await request("approve", [.string(sessionId), .string(approvalId), .string(choiceId)])
  }

  public func answer(sessionId: String, userInputId: String, answers: [QuestionAnswer]) async throws {
    _ = try await request("answer", [.string(sessionId), .string(userInputId), JSONValue(encoding: answers)])
  }

  public func cancelQuestion(sessionId: String, userInputId: String) async throws {
    _ = try await request("cancel-question", [.string(sessionId), .string(userInputId)])
  }

  /// A tool item's full stored output, up to 1 MB.
  public func readOutput(sessionId: String, itemId: String) async throws -> String {
    try await call("output", [.string(sessionId), .string(itemId)])
  }

  /// Asks the backend to quit, then waits for it to exit.
  /// Returns false when the person chose to keep Muse working.
  public func shutdown(timeout: Duration = .seconds(5)) async throws -> Bool {
    let quitting: Bool = try await call("shutdown")
    if quitting { await waitForExit(timeout: timeout) }
    return quitting
  }
}
