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

  /// Reads mMac's preferences from `dataFolder`, gives the backend the bridge token, and connects.
  /// An empty token is not sent.
  public func start(dataFolder: URL, bridgeToken: String = "") async throws -> Started {
    var value: [String: JSONValue] = ["dataFolder": .string(dataFolder.path)]
    if !bridgeToken.isEmpty { value["bridgeToken"] = .string(bridgeToken) }
    return try await call("start", [.object(value)])
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

  /// Starts a conversation. The backend may Ask to trust the project first. With `worktree`, Muse
  /// creates a Git worktree for it under `<project>/.muse/worktrees/`.
  public func create(project: String, modelId: String? = nil, worktree: Bool = false) async throws -> SessionView {
    var args: [JSONValue] = [.string(project)]
    if worktree {
      args += [modelId.map { .string($0) } ?? .null, ["worktree": true]]
    } else if let modelId {
      args.append(.string(modelId))
    }
    return try await call("create", args)
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

  /// Asks Muse to compact the conversation's history. The backend checks trust first.
  public func compact(_ sessionId: String) async throws -> CompactResult {
    try await call("compact", [.string(sessionId)])
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

  /// Writes the open conversation as Markdown to `url`, mode 0600, and returns the path written.
  /// `fallbackTitle` is the sidebar title, used when the conversation has no name or title.
  public func export(sessionId: String, to url: URL, fallbackTitle: String?) async throws -> String {
    var args: [JSONValue] = [.string(sessionId), .string(url.path)]
    if let fallbackTitle { args.append(.string(fallbackTitle)) }
    return try await call("export", args)
  }

  // The inspector. Each checks that the project was opened in mMac.

  public func gitStatus(project: String) async throws -> GitStatus {
    try await call("git-status", [.string(project)])
  }

  /// The staged and working diffs, labelled, or a message for an untracked or binary file.
  public func gitDiff(project: String, path: String) async throws -> String {
    try await call("git-diff", [.string(project), .string(path)])
  }

  /// The plain working-tree diff, whose hunks `revertHunk` counts.
  public func gitRawDiff(project: String, path: String) async throws -> String {
    try await call("git-raw-diff", [.string(project), .string(path)])
  }

  public func revertFile(project: String, path: String) async throws {
    _ = try await request("git-revert-file", [.string(project), .string(path)])
  }

  /// Reverts one working-tree hunk, counted from 0 in the raw diff. With `expected`, the hunk's
  /// text as mMac showed it, the backend refuses when the file's hunk no longer matches.
  public func revertHunk(project: String, path: String, index: Int, expected: String? = nil) async throws {
    var args: [JSONValue] = [.string(project), .string(path), .number(Double(index))]
    if let expected { args.append(.string(expected)) }
    _ = try await request("git-revert-hunk", args)
  }

  public func stageFile(project: String, path: String) async throws {
    _ = try await request("git-stage-file", [.string(project), .string(path)])
  }

  /// The entries of `directory` (empty for the root), folders first.
  public func files(project: String, directory: String = "") async throws -> [ProjectFile] {
    try await call("files", [.string(project), .string(directory)])
  }

  /// A text file of at most 512 KB.
  public func readFile(project: String, path: String) async throws -> String {
    try await call("read-file", [.string(project), .string(path)])
  }

  public func worktrees(project: String) async throws -> [WorktreeEntry] {
    try await call("worktrees", [.string(project)])
  }

  public func mergeWorktree(project: String, path: String) async throws -> MergeResult {
    try await call("worktree-merge", [.string(project), .string(path)])
  }

  /// Removes a Muse worktree. Its branch is kept.
  public func removeWorktree(project: String, path: String) async throws {
    _ = try await request("worktree-remove", [.string(project), .string(path)])
  }

  /// Opens Terminal in the project folder.
  public func openTerminal(project: String) async throws {
    _ = try await request("terminal", [.string(project)])
  }

  /// Opens Terminal in the project folder and starts the Muse Code CLI there.
  public func openCLITerminal(project: String) async throws {
    _ = try await request("cli-terminal", [.string(project)])
  }

  // Settings: MCP servers in Muse's settings.json, and the bridges.

  /// The MCP servers in Muse's settings file, and the file's path.
  public func mcpList() async throws -> McpServerList { try await call("mcp-list") }

  public func mcpAdd(_ server: McpServerInput) async throws {
    _ = try await request("mcp-add", [JSONValue(encoding: server)])
  }

  public func mcpSetEnabled(_ name: String, _ enabled: Bool) async throws {
    _ = try await request("mcp-enabled", [.string(name), .bool(enabled)])
  }

  public func mcpRemove(_ name: String) async throws {
    _ = try await request("mcp-remove", [.string(name)])
  }

  /// Opens Terminal on `muse mcp login <name>`, or `logout`.
  public func mcpLogin(_ name: String, logout: Bool = false) async throws {
    _ = try await request("mcp-login", [.string(name), .bool(logout)])
  }

  public func bridgeStatus() async throws -> BridgeStatus { try await call("bridge-status") }

  /// Makes a new bridge token and returns it. mMac saves it in the Keychain.
  public func bridgeNewToken() async throws -> String { try await call("bridge-token") }

  /// Asks the backend to quit, then waits for it to exit.
  /// Returns false when the person chose to keep Muse working.
  public func shutdown(timeout: Duration = .seconds(5)) async throws -> Bool {
    let quitting: Bool = try await call("shutdown")
    if quitting { await waitForExit(timeout: timeout) }
    return quitting
  }
}
