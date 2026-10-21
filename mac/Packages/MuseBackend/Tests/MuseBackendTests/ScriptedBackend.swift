import Foundation
@testable import MuseBackend

/// A fake backend. Each line mMac sends goes to `script`, which returns the lines to answer with.
final class ScriptedBackend: Transport, @unchecked Sendable {
  let lines: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let script: @Sendable ([String: JSONValue]) -> [String]
  private let lock = NSLock()
  private var received: [[String: JSONValue]] = []
  private var stopped = false

  init(script: @escaping @Sendable ([String: JSONValue]) -> [String] = { _ in [] }) {
    let stream = AsyncStream.makeStream(of: Data.self)
    lines = stream.stream
    continuation = stream.continuation
    self.script = script
  }

  /// Every message mMac sent, decoded. A message is recorded after its replies are pushed,
  /// so a test that sees it can rely on them being on their way.
  var messages: [[String: JSONValue]] { lock.withLock { received } }
  var forceStopped: Bool { lock.withLock { stopped } }

  func send(_ line: Data) throws {
    let message = try JSONDecoder().decode([String: JSONValue].self, from: line)
    for reply in script(message) { push(reply) }
    lock.withLock { received.append(message) }
  }

  /// Sends one line to mMac, as the backend would.
  func push(_ line: String) { continuation.yield(Data(line.utf8)) }

  /// Ends the stream, as the backend does when it exits.
  func close() { continuation.finish() }

  func forceStop() {
    lock.withLock { stopped = true }
    continuation.finish()
  }
}
