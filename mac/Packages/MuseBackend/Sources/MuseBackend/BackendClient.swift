import Foundation

/// mMac's side of the backend protocol: Requests and Replies, Events, and Asks.
public actor BackendClient {
  /// Every `AppEvent` from the backend. It finishes when the backend stops.
  public nonisolated let events: AsyncStream<AppEvent>
  private let eventContinuation: AsyncStream<AppEvent>.Continuation
  private let transport: any Transport
  private let answerAsk: @Sendable (Ask) async -> Int
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var nextId = 1
  private var reader: Task<Void, Never>?
  private var stopped = false

  /// `answerAsk` shows the Ask and returns the chosen button's index, or -1.
  public init(transport: any Transport, answerAsk: @escaping @Sendable (Ask) async -> Int) {
    self.transport = transport
    self.answerAsk = answerAsk
    let stream = AsyncStream.makeStream(of: AppEvent.self)
    events = stream.stream
    eventContinuation = stream.continuation
  }

  /// Starts reading the backend's lines. Call it once, before the first request.
  public func run() {
    guard reader == nil else { return }
    reader = Task {
      for await line in self.transport.lines { self.receive(line) }
      self.finish()
    }
  }

  /// Sends a Request and returns the Reply's value.
  public func request(_ method: String, _ args: [JSONValue] = []) async throws -> JSONValue {
    if stopped { throw BackendError.stopped }
    let id = nextId
    nextId += 1
    let line = try JSONEncoder().encode(OutgoingRequest(id: id, method: method, args: args))
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do {
        try transport.send(line)
      } catch {
        pending.removeValue(forKey: id)
        continuation.resume(throwing: BackendError.stopped)
      }
    }
  }

  /// Sends a Request and decodes the Reply's value as `T`.
  public func call<T: Decodable>(_ method: String, _ args: [JSONValue] = []) async throws -> T {
    try await request(method, args).decode(T.self)
  }

  /// Waits for the backend to exit. Force-stops it after `timeout`.
  public func waitForExit(timeout: Duration) async {
    guard let reader else { return }
    let transport = self.transport
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await reader.value
        return true
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      if await group.next() == false { transport.forceStop() }
      group.cancelAll()
    }
  }

  private func receive(_ line: Data) {
    let incoming: Incoming
    do {
      incoming = try Incoming.decode(line)
    } catch {
      eventContinuation.yield(.error(BackendError.unreadable("\(error)").localizedDescription))
      return
    }
    switch incoming {
    case .reply(let id, let result):
      pending.removeValue(forKey: id)?.resume(with: result.mapError { $0 as Error })
    case .event(let event):
      eventContinuation.yield(event)
    case .ask(let ask):
      Task { [answerAsk, transport] in
        let choice = await answerAsk(ask)
        try? transport.send(JSONEncoder().encode(OutgoingAnswer(answer: ask.ask, choice: choice)))
      }
    }
  }

  private func finish() {
    stopped = true
    for continuation in pending.values { continuation.resume(throwing: BackendError.stopped) }
    pending.removeAll()
    eventContinuation.finish()
  }
}
