import Foundation

/// The backend protocol version. It must equal `HEADLESS_PROTOCOL` in `src/headless/wire.ts`.
public let backendProtocol = 3

public enum BackendError: Error, Equatable, LocalizedError {
  /// The backend's own message. It is written for the person using mMac.
  case backend(String)
  /// The backend sent a line mMac could not read.
  case unreadable(String)
  /// The backend process ended.
  case stopped
  /// The backend is running but did not answer `method` in time, so mMac stopped waiting.
  case noAnswer(method: String, after: Duration)

  public var errorDescription: String? {
    switch self {
    case .backend(let message): message
    case .unreadable(let detail): "mMac could not read a backend message. \(detail)"
    case .stopped: "The Muse backend stopped."
    case .noAnswer(let method, let after):
      "The Muse backend did not answer \(method) within \(Self.seconds(after)) seconds."
    }
  }

  /// `duration` in seconds, without a trailing ".0": "15", "0.2".
  private static func seconds(_ duration: Duration) -> String {
    let (whole, fraction) = duration.components
    return String(format: "%g", Double(whole) + Double(fraction) / 1e18)
  }
}

/// A native alert the backend asks mMac to show. The last button cancels.
public struct Ask: Decodable, Equatable, Sendable {
  public let ask: Int
  public let kind: String
  public let title: String
  public let message: String
  public let detail: String?
  public let buttons: [String]
}

struct OutgoingRequest: Encodable {
  let id: Int
  let method: String
  let args: [JSONValue]
}

struct OutgoingAnswer: Encodable {
  let answer: Int
  let choice: Int
}

enum Incoming {
  case reply(id: Int, result: Result<JSONValue, BackendError>)
  case event(AppEvent)
  case ask(Ask)
  /// An Ask with a readable id but an unreadable body. mMac answers it with -1.
  case unreadableAsk(id: Int)

  private struct EventLine: Decodable { let event: AppEvent }

  static func decode(_ line: Data) throws -> Incoming {
    let decoder = JSONDecoder()
    let object = try decoder.decode([String: JSONValue].self, from: line)
    if case .number(let number)? = object["id"] {
      guard let id = Int(exactly: number) else {
        throw BackendError.unreadable("A reply had an id that is not a whole number.")
      }
      if object["ok"] == .bool(true) { return .reply(id: id, result: .success(object["value"] ?? .null)) }
      if case .string(let message)? = object["error"] { return .reply(id: id, result: .failure(.backend(message))) }
      return .reply(id: id, result: .failure(.unreadable("A reply had no result.")))
    }
    if object["event"] != nil { return .event(try decoder.decode(EventLine.self, from: line).event) }
    if object["ask"] != nil {
      if let ask = try? decoder.decode(Ask.self, from: line) { return .ask(ask) }
      if case .number(let number)? = object["ask"], let id = Int(exactly: number) { return .unreadableAsk(id: id) }
      throw BackendError.unreadable("An Ask had an id that is not a whole number.")
    }
    throw BackendError.unreadable("A line was of no known kind.")
  }
}

/// Splits a byte stream into lines at each newline. The newline is not kept.
struct LineSplitter {
  private var buffer = Data()

  mutating func append(_ data: Data) -> [Data] {
    buffer.append(data)
    var lines: [Data] = []
    while let index = buffer.firstIndex(of: 0x0A) {
      lines.append(Data(buffer[buffer.startIndex..<index]))
      buffer.removeSubrange(buffer.startIndex...index)
    }
    return lines
  }
}
