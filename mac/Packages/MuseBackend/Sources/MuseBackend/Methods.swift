import Foundation

// Typed M0 methods. Names and arguments match src/headless/server.ts.
extension BackendClient {
  /// Checks that mMac and the backend speak one protocol. A mismatch stops the backend.
  public func hello() async throws -> Hello {
    try await call("hello", [.number(Double(backendProtocol))])
  }

  /// Reads mMac's preferences from `dataFolder` and connects to Muse.
  public func start(dataFolder: URL) async throws -> Started {
    try await call("start", [["dataFolder": .string(dataFolder.path)]])
  }

  public func connect() async throws -> ConnectionStatus { try await call("connect") }

  /// Adds a folder chosen in mMac's panel to the recent projects. Returns its real path.
  public func addProject(_ folder: URL) async throws -> String {
    try await call("add-project", [.string(folder.path)])
  }

  public func sessions() async throws -> SessionList { try await call("sessions") }

  /// Starts a conversation. The backend may Ask to trust the project first.
  public func create(project: String) async throws -> SessionView {
    try await call("create", [.string(project)])
  }

  public func open(_ sessionId: String) async throws -> SessionView {
    try await call("open", [.string(sessionId)])
  }

  public func send(sessionId: String, text: String, effort: String = "high") async throws {
    _ = try await request("send", [
      [
        "sessionId": .string(sessionId), "text": .string(text), "attachments": [],
        "effort": .string(effort), "mode": "queue",
      ]
    ])
  }

  public func cancel(_ sessionId: String) async throws {
    _ = try await request("cancel", [.string(sessionId)])
  }

  /// Asks the backend to quit, then waits for it to exit.
  /// Returns false when the person chose to keep Muse working.
  public func shutdown(timeout: Duration = .seconds(5)) async throws -> Bool {
    let quitting: Bool = try await call("shutdown")
    if quitting { await waitForExit(timeout: timeout) }
    return quitting
  }
}
