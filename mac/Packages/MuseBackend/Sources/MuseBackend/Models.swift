import Foundation

// The M0 subset of src/shared/protocol.ts. Fields mMac does not use yet are
// left out; decoding ignores them. Add fields as later milestones need them.

public struct ConnectionStatus: Codable, Equatable, Sendable {
  /// `connecting`, `ready`, `missing` or `error`.
  public let state: String
  public let path: String?
  public let version: String?
  public let message: String?

  public init(state: String, path: String?, version: String?, message: String?) {
    self.state = state
    self.path = path
    self.version = version
    self.message = message
  }
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
  public let sessionId: String
  public let workspaceRoot: String?
  public let status: String
  public let updatedAt: String
  public let name: String?
  public let title: String?
  public let firstUserPrompt: String?
  public var id: String { sessionId }
}

public struct SessionList: Codable, Equatable, Sendable {
  public let sessions: [Session]
  public let nextCursor: String?
}

public struct TranscriptItem: Codable, Equatable, Sendable, Identifiable {
  public let itemId: String
  public let kind: String
  public let status: String
  public let text: String?
  public let displayText: String?
  public var id: String { itemId }
}

public struct SessionView: Codable, Equatable, Sendable {
  public let session: Session
  public let items: [TranscriptItem]
  public let error: String?
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
  public let status: ConnectionStatus
}

/// `AppEvent` from src/shared/protocol.ts.
public enum AppEvent: Decodable, Equatable, Sendable {
  case connection(ConnectionStatus)
  case session(SessionView)
  case sessionsChanged
  case error(String)
  /// An event mMac does not show yet, such as `preferences` or `menu`.
  case other(String)

  private enum Keys: String, CodingKey { case type, status, view, message }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "connection": self = .connection(try container.decode(ConnectionStatus.self, forKey: .status))
    case "session": self = .session(try container.decode(SessionView.self, forKey: .view))
    case "sessions-changed": self = .sessionsChanged
    case "error": self = .error(try container.decode(String.self, forKey: .message))
    default: self = .other(type)
    }
  }
}
