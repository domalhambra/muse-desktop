import Foundation

// The M1 subset of src/shared/protocol.ts. Decoding ignores fields mMac does not use.
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
  public let title: String?
  public let firstUserPrompt: String?
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

public struct Approval: Codable, Equatable, Sendable, Identifiable {
  public struct Subject: Codable, Equatable, Sendable {
    public let kind: String
    public let command: String?
    public let path: String?
    public let host: String?
    public let target: String?
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
  }

  public let approvalId: String
  public let sessionId: String
  public let toolName: String
  public let rawArgs: String
  public let subject: Subject
  public let availableChoices: [Choice]
  public var id: String { approvalId }
}

public struct UserQuestion: Codable, Equatable, Sendable, Identifiable {
  public struct Option: Codable, Equatable, Sendable, Identifiable {
    public let label: String
    public let description: String?
    public var id: String { label }
  }

  public struct Selection: Codable, Equatable, Sendable {
    /// `single` or `multiple`.
    public let mode: String
    public let minSelections: Int?
    public let maxSelections: Int?
  }

  public struct Prompt: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [Option]
    public let selection: Selection
  }

  public let userInputId: String
  public let sessionId: String
  public let questions: [Prompt]
  public var id: String { userInputId }
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
}

/// The preferences mMac reads. The backend sends them whole on `start` and after every save.
public struct Preferences: Codable, Equatable, Sendable {
  public let cliPath: String
  public let recentProjects: [String]
  public let trustedProjects: [String]
  public let reasoningEffort: String

  public init(cliPath: String = "", recentProjects: [String] = [], trustedProjects: [String] = [], reasoningEffort: String = "high") {
    self.cliPath = cliPath
    self.recentProjects = recentProjects
    self.trustedProjects = trustedProjects
    self.reasoningEffort = reasoningEffort
  }
}

/// The preference fields mMac may change. Fields left nil are not sent.
public struct PreferencesPatch: Encodable, Equatable, Sendable {
  public var cliPath: String?
  public var reasoningEffort: String?

  public init(cliPath: String? = nil, reasoningEffort: String? = nil) {
    self.cliPath = cliPath
    self.reasoningEffort = reasoningEffort
  }
}

public struct SessionView: Codable, Equatable, Sendable {
  public var session: Session
  public var items: [TranscriptItem]
  public var approvals: [Approval]
  public var questions: [UserQuestion]
  public let error: String?
  public let historyNotice: String?

  public init(
    session: Session, items: [TranscriptItem] = [], approvals: [Approval] = [],
    questions: [UserQuestion] = [], error: String? = nil, historyNotice: String? = nil
  ) {
    self.session = session
    self.items = items
    self.approvals = approvals
    self.questions = questions
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
