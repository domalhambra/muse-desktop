import Foundation
import os

/// mMac's side of the backend protocol: Requests and Replies, Events, and Asks.
public actor BackendClient {
  /// Every `AppEvent` from the backend. It finishes when the backend stops. Read it from one place only.
  public nonisolated let events: AsyncStream<AppEvent>
  private let eventContinuation: AsyncStream<AppEvent>.Continuation
  private let transport: any Transport
  private let answerAsk: @Sendable (Ask) async -> Int
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var nextId = 1
  private var reader: Task<Void, Never>?
  private var stopped = false

  private static let log = Logger(subsystem: "com.domalhambra.mmac", category: "backend")

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

  /// Sends a Request and returns the Reply's value. If the calling task is cancelled, this throws
  /// `CancellationError` at once and ignores the Reply when it comes. The backend still finishes
  /// the request; cancelling only stops waiting.
  public func request(_ method: String, _ args: [JSONValue] = []) async throws -> JSONValue {
    if stopped { throw BackendError.stopped }
    try Task.checkCancellation()
    let id = nextId
    nextId += 1
    let line = try JSONEncoder().encode(OutgoingRequest(id: id, method: method, args: args))
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Cancelled between the check above and here: the handler found nothing to cancel.
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        pending[id] = continuation
        do {
          try transport.send(line)
        } catch {
          pending.removeValue(forKey: id)
          continuation.resume(throwing: BackendError.stopped)
        }
      }
    } onCancel: {
      Task { await self.abandon(id) }
    }
  }

  /// Stops waiting for a request whose caller was cancelled.
  private func abandon(_ id: Int) {
    pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  /// Stops the backend at once. Used when a second Quit finds it never answered `shutdown`.
  public nonisolated func forceStop() { transport.forceStop() }

  /// Sends a Request and decodes the Reply's value as `T`.
  public func call<T: Decodable>(_ method: String, _ args: [JSONValue] = []) async throws -> T {
    let value = try await request(method, args)
    do {
      return try value.decode(T.self)
    } catch is DecodingError {
      throw BackendError.unreadable("The \(method) reply did not match what mMac expects.")
    }
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
    } catch let error as BackendError {
      eventContinuation.yield(.error(error.localizedDescription))
      return
    } catch {
      Self.log.error("A backend line could not be decoded: \(String(describing: error), privacy: .public)")
      eventContinuation.yield(.error(BackendError.unreadable("A line could not be decoded.").localizedDescription))
      return
    }
    switch incoming {
    case .reply(let id, let result):
      pending.removeValue(forKey: id)?.resume(with: result.mapError { $0 as Error })
    case .event(let event):
      eventContinuation.yield(event)
    case .ask(let ask):
      Task { [answerAsk] in
        let choice = await answerAsk(ask)
        self.answer(ask, choice: choice)
      }
    case .unreadableAsk(let id):
      // Cancel it, as wire.ts replies to a malformed request with a readable id.
      send(answer: id, choice: -1)
      eventContinuation.yield(.error(BackendError.unreadable("An Ask could not be decoded.").localizedDescription))
    }
  }

  /// Sends the person's choice. A choice that names no button cancels.
  private func answer(_ ask: Ask, choice: Int) {
    send(answer: ask.ask, choice: (-1..<ask.buttons.count).contains(choice) ? choice : -1)
  }

  private func send(answer id: Int, choice: Int) {
    guard !stopped else { return }
    try? transport.send(JSONEncoder().encode(OutgoingAnswer(answer: id, choice: choice)))
  }

  private func finish() {
    stopped = true
    for continuation in pending.values { continuation.resume(throwing: BackendError.stopped) }
    pending.removeAll()
    eventContinuation.finish()
  }
}
