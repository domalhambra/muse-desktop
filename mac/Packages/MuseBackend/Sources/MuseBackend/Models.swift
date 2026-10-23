import Foundation

// The subset of src/shared/protocol.ts mMac uses. Decoding ignores fields mMac does not use.
// Optional fields here are optional or nullable in the zod schemas.

public struct ConnectionStatus: Codable, Equatable, Sendable {
  /// `connecting`, `ready`, `missing` or `error`.
  public let state: String
  public let path: String?
  public let version: String?
  public let message: String?
  public let fingerprintWarning: String?
  public let experimental: Bool?

  public init(
    state: String, path: String? = nil, version: String? = nil, message: String? = nil,
    fingerprintWarning: String? = nil, experimental: Bool? = nil
  ) {
    self.state = state
    self.path = path
    self.version = version
    self.message = message
    self.fingerprintWarning = fingerprintWarning
    self.experimental = experimental
  }

  public var isReady: Bool { state == "ready" }
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
  public struct Worktree: Codable, Equatable, Sendable {
    public let path: String
    public let origin: String
  }

  public let sessionId: String
  public let workspaceRoot: String?
  public let createdAt: String?
  public let updatedAt: String
  public let lastActivityAt: String?
  /// `idle`, `running` or another CLI status.
  public var status: String
  public let activeTurnId: String?
  public var modelId: String?
  public var name: String?
  public var title: String?
  public var firstUserPrompt: String?
  /// `subagent` and `reminder` sessions never show in the sidebar.
  public let kind: String?
  public let worktree: Worktree?
  public var id: String { sessionId }

  public init(
    sessionId: String, workspaceRoot: String? = nil, createdAt: String? = nil,
    updatedAt: String, lastActivityAt: String? = nil, status: String = "idle",
    activeTurnId: String? = nil, modelId: String? = nil, name: String? = nil,
    title: String? = nil, firstUserPrompt: String? = nil, kind: String? = nil,
    worktree: Worktree? = nil
  ) {
    self.sessionId = sessionId
    self.workspaceRoot = workspaceRoot
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastActivityAt = lastActivityAt
    self.status = status
    self.activeTurnId = activeTurnId
    self.modelId = modelId
    self.name = name
    self.title = title
    self.firstUserPrompt = firstUserPrompt
    self.kind = kind
    self.worktree = worktree
  }
}

public struct SessionList: Codable, Equatable, Sendable {
  public let sessions: [Session]
  public let nextCursor: String?
}

public struct TranscriptItem: Codable, Equatable, Sendable, Identifiable {
  public struct OutputRef: Codable, Equatable, Sendable {
    public let id: String
    public let byteLen: Int?
    public init(id: String, byteLen: Int? = nil) {
      self.id = id
      self.byteLen = byteLen
    }
  }

  public struct PatchSummary: Codable, Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public let files: Int
    public init(added: Int, removed: Int, files: Int) {
      self.added = added
      self.removed = removed
      self.files = files
    }
  }

  public struct ToolResult: Codable, Equatable, Sendable {
    public let text: String?
    public let summary: String?
    public init(text: String? = nil, summary: String? = nil) {
      self.text = text
      self.summary = summary
    }
  }

  public let itemId: String
  /// `userMessage`, `agentMessage`, `reasoning`, `toolCall`, `reminderChild`, `hookRun` and more.
  public let kind: String
  public let revision: Int
  /// `inProgress`, `completed`, or a failure status.
  public let status: String
  public let text: String?
  public let displayText: String?
  public let summary: [String]?
  public let tool: String?
  public let args: String?
  public let visibleOutput: String?
  public let commandText: String?
  public let fallbackText: String?
  public let statusLine: String?
  public let failureReason: String?
  public let objective: String?
  public let role: String?
  public let label: String?
  public let finalSummary: String?
  public let recordedAt: String?
  public let reminderAgentId: String?
  public let durationMs: Double?
  public let truncated: Bool?
  public let retracted: Bool?
  public let blocking: Bool?
  public let outputRef: OutputRef?
  public let patchSummary: PatchSummary?
  public let result: ToolResult?
  public var id: String { itemId }

  public init(
    itemId: String, kind: String, revision: Int = 0, status: String, text: String? = nil,
    displayText: String? = nil, summary: [String]? = nil, tool: String? = nil,
    args: String? = nil, visibleOutput: String? = nil, commandText: String? = nil,
    fallbackText: String? = nil, statusLine: String? = nil, failureReason: String? = nil,
    objective: String? = nil, role: String? = nil, label: String? = nil,
    finalSummary: String? = nil, recordedAt: String? = nil, reminderAgentId: String? = nil,
    durationMs: Double? = nil, truncated: Bool? = nil, retracted: Bool? = nil,
    blocking: Bool? = nil, outputRef: OutputRef? = nil, patchSummary: PatchSummary? = nil,
    result: ToolResult? = nil
  ) {
    self.itemId = itemId
    self.kind = kind
    self.revision = revision
    self.status = status
    self.text = text
    self.displayText = displayText
    self.summary = summary
    self.tool = tool
    self.args = args
    self.visibleOutput = visibleOutput
    self.commandText = commandText
    self.fallbackText = fallbackText
    self.statusLine = statusLine
    self.failureReason = failureReason
    self.objective = objective
    self.role = role
    self.label = label
    self.finalSummary = finalSummary
    self.recordedAt = recordedAt
    self.reminderAgentId = reminderAgentId
    self.durationMs = durationMs
    self.truncated = truncated
    self.retracted = retracted
    self.blocking = blocking
    self.outputRef = outputRef
    self.patchSummary = patchSummary
    self.result = result
  }
}

extension TranscriptItem {
  /// The synthesized decoding, except `summary`: muse-host.ts fills it by index, so a skipped
  /// index arrives as null. Those are dropped rather than failing the whole session view.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    itemId = try c.decode(String.self, forKey: .itemId)
    kind = try c.decode(String.self, forKey: .kind)
    revision = try c.decode(Int.self, forKey: .revision)
    status = try c.decode(String.self, forKey: .status)
    text = try c.decodeIfPresent(String.self, forKey: .text)
    displayText = try c.decodeIfPresent(String.self, forKey: .displayText)
    summary = try c.decodeIfPresent([String?].self, forKey: .summary)?.compactMap { $0 }
    tool = try c.decodeIfPresent(String.self, forKey: .tool)
    args = try c.decodeIfPresent(String.self, forKey: .args)
    visibleOutput = try c.decodeIfPresent(String.self, forKey: .visibleOutput)
    commandText = try c.decodeIfPresent(String.self, forKey: .commandText)
    fallbackText = try c.decodeIfPresent(String.self, forKey: .fallbackText)
    statusLine = try c.decodeIfPresent(String.self, forKey: .statusLine)
    failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
    objective = try c.decodeIfPresent(String.self, forKey: .objective)
    role = try c.decodeIfPresent(String.self, forKey: .role)
    label = try c.decodeIfPresent(String.self, forKey: .label)
    finalSummary = try c.decodeIfPresent(String.self, forKey: .finalSummary)
    recordedAt = try c.decodeIfPresent(String.self, forKey: .recordedAt)
    reminderAgentId = try c.decodeIfPresent(String.self, forKey: .reminderAgentId)
    durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
    truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated)
    retracted = try c.decodeIfPresent(Bool.self, forKey: .retracted)
    blocking = try c.decodeIfPresent(Bool.self, forKey: .blocking)
    outputRef = try c.decodeIfPresent(OutputRef.self, forKey: .outputRef)
    patchSummary = try c.decodeIfPresent(PatchSummary.self, forKey: .patchSummary)
    result = try c.decodeIfPresent(ToolResult.self, forKey: .result)
  }
}

public struct Approval: Codable, Equatable, Sendable, Identifiable {
  public struct Subject: Codable, Equatable, Sendable {
    public let kind: String
    public let command: String?
    public let path: String?
    public let host: String?
    public let target: String?

    public init(kind: String, command: String? = nil, path: String? = nil, host: String? = nil, target: String? = nil) {
      self.kind = kind
      self.command = command
      self.path = path
      self.host = host
      self.target = target
    }
  }

  public struct Choice: Codable, Equatable, Sendable, Identifiable {
    public let choiceId: String
    public let label: String
    public let decision: String
    /// `once`, `session` or `localPersistent`.
    public let scope: String
    public let rulePreview: String?
    public let acceptsFeedback: Bool?
    public var id: String { choiceId }

    public init(
      choiceId: String, label: String, decision: String, scope: String, rulePreview: String? = nil,
      acceptsFeedback: Bool? = nil
    ) {
      self.choiceId = choiceId
      self.label = label
      self.decision = decision
      self.scope = scope
      self.rulePreview = rulePreview
      self.acceptsFeedback = acceptsFeedback
    }
  }

  public let approvalId: String
  public let sessionId: String
  public let toolName: String
  public let rawArgs: String
  public let subject: Subject
  public let availableChoices: [Choice]
  public var id: String { approvalId }

  public init(
    approvalId: String, sessionId: String, toolName: String, rawArgs: String, subject: Subject,
    availableChoices: [Choice]
  ) {
    self.approvalId = approvalId
    self.sessionId = sessionId
    self.toolName = toolName
    self.rawArgs = rawArgs
    self.subject = subject
    self.availableChoices = availableChoices
  }
}

public struct UserQuestion: Codable, Equatable, Sendable, Identifiable {
  public struct Option: Codable, Equatable, Sendable, Identifiable {
    public let label: String
    public let description: String?
    public var id: String { label }

    public init(label: String, description: String? = nil) {
      self.label = label
      self.description = description
    }
  }

  public struct Selection: Codable, Equatable, Sendable {
    /// `single` or `multiple`.
    public let mode: String
    public let minSelections: Int?
    public let maxSelections: Int?

    public init(mode: String, minSelections: Int? = nil, maxSelections: Int? = nil) {
      self.mode = mode
      self.minSelections = minSelections
      self.maxSelections = maxSelections
    }
  }

  public struct Prompt: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [Option]
    public let selection: Selection

    public init(id: String, header: String, question: String, options: [Option], selection: Selection) {
      self.id = id
      self.header = header
      self.question = question
      self.options = options
      self.selection = selection
    }
  }

  public let userInputId: String
  public let sessionId: String
  public let questions: [Prompt]
  public var id: String { userInputId }

  public init(userInputId: String, sessionId: String, questions: [Prompt]) {
    self.userInputId = userInputId
    self.sessionId = sessionId
    self.questions = questions
  }
}

/// One answer to one prompt. It carries either a selection or free text, never both.
public struct QuestionAnswer: Codable, Equatable, Sendable {
  public let questionId: String
  public var selectedLabel: String?
  public var selectedLabels: [String]?
  public var freeText: String?

  public init(
    questionId: String, selectedLabel: String? = nil, selectedLabels: [String]? = nil,
    freeText: String? = nil
  ) {
    self.questionId = questionId
    self.selectedLabel = selectedLabel
    self.selectedLabels = selectedLabels
    self.freeText = freeText
  }
}

public struct MuseModel: Codable, Equatable, Sendable, Identifiable {
  public let modelId: String
  public let displayLabel: String
  public let providerId: String
  public let isDefault: Bool
  public let isActive: Bool
  public let contextLimit: Int?
  public var id: String { modelId }

  public init(
    modelId: String, displayLabel: String, providerId: String, isDefault: Bool, isActive: Bool,
    contextLimit: Int? = nil
  ) {
    self.modelId = modelId
    self.displayLabel = displayLabel
    self.providerId = providerId
    self.isDefault = isDefault
    self.isActive = isActive
    self.contextLimit = contextLimit
  }
}

/// The preferences mMac reads. The backend sends them whole on `start` and after every save.
/// A field the file lacks takes Electron's default (`src/shared/protocol.ts`).
public struct Preferences: Codable, Equatable, Sendable {
  public var cliPath = ""
  public var recentProjects: [String] = []
  public var trustedProjects: [String] = []
  public var reasoningEffort = "high"
  public var theme = "muse"
  public var fontSize = "comfortable"
  public var reduceMotion = false
  public var notifyOnCompletion = false
  public var bridgeFilesEnabled = false
  public var bridgeMcpEnabled = false
  public var bridgeMcpPort = 7735

  public init(
    cliPath: String = "", recentProjects: [String] = [], trustedProjects: [String] = [],
    reasoningEffort: String = "high", theme: String = "muse", fontSize: String = "comfortable",
    reduceMotion: Bool = false, notifyOnCompletion: Bool = false, bridgeFilesEnabled: Bool = false,
    bridgeMcpEnabled: Bool = false, bridgeMcpPort: Int = 7735
  ) {
    self.cliPath = cliPath
    self.recentProjects = recentProjects
    self.trustedProjects = trustedProjects
    self.reasoningEffort = reasoningEffort
    self.theme = theme
    self.fontSize = fontSize
    self.reduceMotion = reduceMotion
    self.notifyOnCompletion = notifyOnCompletion
    self.bridgeFilesEnabled = bridgeFilesEnabled
    self.bridgeMcpEnabled = bridgeMcpEnabled
    self.bridgeMcpPort = bridgeMcpPort
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Preferences()
    cliPath = try c.decodeIfPresent(String.self, forKey: .cliPath) ?? d.cliPath
    recentProjects = try c.decodeIfPresent([String].self, forKey: .recentProjects) ?? d.recentProjects
    trustedProjects = try c.decodeIfPresent([String].self, forKey: .trustedProjects) ?? d.trustedProjects
    reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? d.reasoningEffort
    theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
    fontSize = try c.decodeIfPresent(String.self, forKey: .fontSize) ?? d.fontSize
    reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? d.reduceMotion
    notifyOnCompletion = try c.decodeIfPresent(Bool.self, forKey: .notifyOnCompletion) ?? d.notifyOnCompletion
    bridgeFilesEnabled = try c.decodeIfPresent(Bool.self, forKey: .bridgeFilesEnabled) ?? d.bridgeFilesEnabled
    bridgeMcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .bridgeMcpEnabled) ?? d.bridgeMcpEnabled
    bridgeMcpPort = try c.decodeIfPresent(Int.self, forKey: .bridgeMcpPort) ?? d.bridgeMcpPort
  }
}

/// The preference fields mMac may change. Fields left nil are not sent.
public struct PreferencesPatch: Encodable, Equatable, Sendable {
  public var cliPath: String?
  public var reasoningEffort: String?
  public var theme: String?
  public var fontSize: String?
  public var reduceMotion: Bool?
  public var notifyOnCompletion: Bool?
  public var bridgeFilesEnabled: Bool?
  public var bridgeMcpEnabled: Bool?
  public var bridgeMcpPort: Int?

  public init(
    cliPath: String? = nil, reasoningEffort: String? = nil, theme: String? = nil, fontSize: String? = nil,
    reduceMotion: Bool? = nil, notifyOnCompletion: Bool? = nil, bridgeFilesEnabled: Bool? = nil,
    bridgeMcpEnabled: Bool? = nil, bridgeMcpPort: Int? = nil
  ) {
    self.cliPath = cliPath
    self.reasoningEffort = reasoningEffort
    self.theme = theme
    self.fontSize = fontSize
    self.reduceMotion = reduceMotion
    self.notifyOnCompletion = notifyOnCompletion
    self.bridgeFilesEnabled = bridgeFilesEnabled
    self.bridgeMcpEnabled = bridgeMcpEnabled
    self.bridgeMcpPort = bridgeMcpPort
  }

  /// True when the patch changes a bridge, so the bridge status needs a new read.
  public var touchesBridges: Bool { bridgeFilesEnabled != nil || bridgeMcpEnabled != nil || bridgeMcpPort != nil }
}

public struct SessionView: Codable, Equatable, Sendable {
  public var session: Session
  public var items: [TranscriptItem]
  public var approvals: [Approval]
  public var questions: [UserQuestion]
  public var usage: Usage?
  public let error: String?
  public let historyNotice: String?

  public init(
    session: Session, items: [TranscriptItem] = [], approvals: [Approval] = [],
    questions: [UserQuestion] = [], usage: Usage? = nil, error: String? = nil,
    historyNotice: String? = nil
  ) {
    self.session = session
    self.items = items
    self.approvals = approvals
    self.questions = questions
    self.usage = usage
    self.error = error
    self.historyNotice = historyNotice
  }
}

public struct Hello: Decodable, Equatable, Sendable {
  public let protocolVersion: Int
  public let version: String
  private enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol"
    case version
  }
}

public struct Started: Decodable, Sendable {
  public let preferences: Preferences
  public let status: ConnectionStatus

  public init(preferences: Preferences, status: ConnectionStatus) {
    self.preferences = preferences
    self.status = status
  }
}

/// `AppEvent` from src/shared/protocol.ts.
public enum AppEvent: Decodable, Equatable, Sendable {
  case connection(ConnectionStatus)
  case session(SessionView)
  case sessionsChanged
  case preferences(Preferences)
  case error(String)
  /// An event mMac does not use, such as `menu`.
  case other(String)

  private enum Keys: String, CodingKey { case type, status, view, message, preferences }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "connection": self = .connection(try container.decode(ConnectionStatus.self, forKey: .status))
    case "session": self = .session(try container.decode(SessionView.self, forKey: .view))
    case "sessions-changed": self = .sessionsChanged
    case "preferences": self = .preferences(try container.decode(Preferences.self, forKey: .preferences))
    case "error": self = .error(try container.decode(String.self, forKey: .message))
    default: self = .other(type)
    }
  }
}

// The inspector's replies, from src/shared/protocol.ts.

public struct GitChange: Codable, Equatable, Sendable, Identifiable {
  public let path: String
  /// The porcelain status without spaces: `M`, `A`, `D`, `R`, `MM`, or `??` for untracked.
  public let status: String
  public let staged: Bool
  public var id: String { path }

  public init(path: String, status: String, staged: Bool) {
    self.path = path
    self.status = status
    self.staged = staged
  }
}

public struct GitStatus: Codable, Equatable, Sendable {
  /// The branch name, `Detached HEAD`, or empty outside a repository.
  public let branch: String
  public let changes: [GitChange]
  public let isRepository: Bool

  public init(branch: String, changes: [GitChange], isRepository: Bool) {
    self.branch = branch
    self.changes = changes
    self.isRepository = isRepository
  }
}

public struct ProjectFile: Codable, Equatable, Sendable, Identifiable {
  public let name: String
  /// Relative to the project root, with `/`.
  public let path: String
  public let directory: Bool
  public var id: String { path }

  public init(name: String, path: String, directory: Bool) {
    self.name = name
    self.path = path
    self.directory = directory
  }
}

public struct WorktreeEntry: Codable, Equatable, Sendable, Identifiable {
  public let path: String
  public let branch: String?
  public let isMain: Bool
  public let sessionIds: [String]
  public var id: String { path }

  public init(path: String, branch: String? = nil, isMain: Bool, sessionIds: [String] = []) {
    self.path = path
    self.branch = branch
    self.isMain = isMain
    self.sessionIds = sessionIds
  }
}

/// `worktree-merge` answers with this instead of failing, so its message reaches the person.
public struct MergeResult: Codable, Equatable, Sendable {
  public let ok: Bool
  public let output: String

  public init(ok: Bool, output: String) {
    self.ok = ok
    self.output = output
  }
}

/// A conversation's token counts.
public struct Usage: Codable, Equatable, Sendable {
  public let input: Int
  public let output: Int
  public let total: Int

  public init(input: Int, output: Int, total: Int) {
    self.input = input
    self.output = output
    self.total = total
  }
}

// M4a's replies, from src/shared/protocol.ts.

/// `compact`'s reply. `noop` means the conversation had no history to compact.
public struct CompactResult: Codable, Equatable, Sendable {
  public let status: String

  public init(status: String) {
    self.status = status
  }
}

/// A file chosen for the next message. The backend keeps its path; mMac sends the id with `send`.
public struct Attachment: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  /// `image` or `text`, from the file's extension.
  public let kind: String
  /// In bytes.
  public let size: Int

  public init(id: String, name: String, kind: String, size: Int) {
    self.id = id
    self.name = name
    self.kind = kind
    self.size = size
  }
}

// Settings: MCP servers and the bridges, from src/shared/protocol.ts.

/// An MCP server from Muse's settings.json. Secret values never leave the backend.
public struct McpServer: Codable, Equatable, Sendable, Identifiable {
  public let name: String
  /// `stdio` or `http`.
  public let transport: String
  public let enabled: Bool
  public let command: String?
  public let args: [String]?
  public let url: String?
  public let envNames: [String]?
  public let headerNames: [String]?
  public var id: String { name }
  public var isRemote: Bool { transport == "http" }
  /// The command line or the URL, as Electron's row shows it.
  public var detail: String { isRemote ? url ?? "" : ([command ?? ""] + (args ?? [])).joined(separator: " ") }
  /// The names of the env variables or headers, never their values.
  public var secretNames: [String] { (isRemote ? headerNames : envNames) ?? [] }

  public init(
    name: String, transport: String, enabled: Bool, command: String? = nil, args: [String]? = nil,
    url: String? = nil, envNames: [String]? = nil, headerNames: [String]? = nil
  ) {
    self.name = name
    self.transport = transport
    self.enabled = enabled
    self.command = command
    self.args = args
    self.url = url
    self.envNames = envNames
    self.headerNames = headerNames
  }
}

/// `mcp-list`'s reply: the servers and the settings file they come from.
public struct McpServerList: Codable, Equatable, Sendable {
  public let file: String
  public let servers: [McpServer]

  public init(file: String, servers: [McpServer]) {
    self.file = file
    self.servers = servers
  }
}

/// A server to add, in the shape `mcpServerSchema` reads.
public enum McpServerInput: Encodable, Equatable, Sendable {
  case stdio(name: String, command: String, args: [String], env: [String: String])
  case http(name: String, url: String, headers: [String: String])

  private enum Keys: String, CodingKey { case name, transport, command, args, env, url, headers }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    switch self {
    case .stdio(let name, let command, let args, let env):
      try c.encode(name, forKey: .name)
      try c.encode("stdio", forKey: .transport)
      try c.encode(command, forKey: .command)
      try c.encode(args, forKey: .args)
      try c.encode(env, forKey: .env)
    case .http(let name, let url, let headers):
      try c.encode(name, forKey: .name)
      try c.encode("http", forKey: .transport)
      try c.encode(url, forKey: .url)
      try c.encode(headers, forKey: .headers)
    }
  }
}

/// The folder bridge and the MCP bridge, as `bridge-status` reports them.
public struct BridgeStatus: Codable, Equatable, Sendable {
  public struct Part: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let running: Bool
    public let error: String?

    public init(enabled: Bool, running: Bool, error: String? = nil) {
      self.enabled = enabled
      self.running = running
      self.error = error
    }
  }

  public struct Mcp: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let running: Bool
    public let url: String
    public let hasToken: Bool
    public let error: String?

    public init(enabled: Bool, running: Bool, url: String, hasToken: Bool, error: String? = nil) {
      self.enabled = enabled
      self.running = running
      self.url = url
      self.hasToken = hasToken
      self.error = error
    }
  }

  public let folder: String
  public let files: Part
  public let mcp: Mcp
  public let activeJobs: Int

  public init(folder: String, files: Part, mcp: Mcp, activeJobs: Int) {
    self.folder = folder
    self.files = files
    self.mcp = mcp
    self.activeJobs = activeJobs
  }
}
