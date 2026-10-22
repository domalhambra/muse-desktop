import Foundation
import Testing
import MuseBackendTesting
@testable import MuseBackend

private let viewJSON = #"""
  {"session":{"sessionId":"s1","workspaceRoot":"/p","status":"idle","updatedAt":"2026-10-21T00:00:00Z","createdAt":"2026-10-21T00:00:00Z","activeTurnId":null,"modelId":null,"turnCount":1},"items":[{"itemId":"i1","kind":"agentMessage","revision":1,"status":"completed","text":"Hello"}],"approvals":[],"questions":[]}
  """#

@Test func helloSendsTheProtocolNumber() async throws {
  let backend = ScriptedBackend { message in
    message["method"] == "hello" ? [#"{"id":1,"ok":true,"value":{"protocol":1,"version":"0.2.0"}}"#] : []
  }
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  let hello = try await client.hello()
  #expect(hello.protocolVersion == 1)
  #expect(hello.version == "0.2.0")
  #expect(backend.messages == [["id": 1, "method": "hello", "args": [1]]])
}

@Test func aFailedReplyThrowsTheBackendMessage() async throws {
  let backend = ScriptedBackend { _ in [#"{"id":1,"ok":false,"error":"Send start first."}"#] }
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  await #expect(throws: BackendError.backend("Send start first.")) {
    _ = try await client.sessions()
  }
}

@Test(.timeLimit(.minutes(1))) func eventsArriveTypedAndInOrder() async throws {
  let backend = ScriptedBackend()
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  backend.push(#"{"event":{"type":"connection","status":{"state":"ready","version":"1.4.11"}}}"#)
  backend.push(#"{"event":{"type":"session","view":\#(viewJSON)}}"#)
  backend.push(#"{"event":{"type":"sessions-changed"}}"#)
  backend.push(#"{"event":{"type":"menu","action":"new"}}"#)
  backend.push(#"{"event":{"type":"error","message":"Could not read a Muse update."}}"#)
  var received: [AppEvent] = []
  for await event in client.events {
    received.append(event)
    if received.count == 5 { break }
  }
  #expect(received[0] == .connection(ConnectionStatus(state: "ready", path: nil, version: "1.4.11", message: nil)))
  guard case .session(let view) = received[1] else { Issue.record("Expected a session event"); return }
  #expect(view.items.first?.text == "Hello")
  #expect(received[2] == .sessionsChanged)
  #expect(received[3] == .other("menu"))
  #expect(received[4] == .error("Could not read a Muse update."))
}

@Test(.timeLimit(.minutes(1))) func anAskIsAnsweredWhileItsRequestWaits() async throws {
  // create is this client's first request, so its id is 1.
  let backend = ScriptedBackend { message in
    if message["method"] == "create" {
      return [#"{"ask":3,"kind":"confirm","title":"Trust this project?","message":"Work with Muse in “p”?","buttons":["Trust project","Cancel"]}"#]
    }
    if message["answer"] == 3 { return [#"{"id":1,"ok":true,"value":\#(viewJSON)}"#] }
    return []
  }
  let client = BackendClient(transport: backend, answerAsk: { ask in
    ask.buttons.firstIndex(of: "Trust project") ?? -1
  })
  await client.run()
  let view = try await client.create(project: "/p")
  #expect(view.session.sessionId == "s1")
  #expect(backend.messages.contains { $0["answer"] == 3 && $0["choice"] == 0 })
}

@Test(.timeLimit(.minutes(1))) func waitingRequestsFailWhenTheBackendStops() async throws {
  let backend = ScriptedBackend()
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  let reply = Task { try await client.sessions() }
  try await waitFor { backend.messages.count == 1 }  // The request is really pending.
  backend.close()
  await #expect(throws: BackendError.stopped) { _ = try await reply.value }
  for await _ in client.events {}  // The stream finishes instead of hanging.
}

@Test(.timeLimit(.minutes(1))) func shutdownForceStopsABackendThatDoesNotExit() async throws {
  let backend = ScriptedBackend { message in
    message["method"] == "shutdown" ? [#"{"id":1,"ok":true,"value":true}"#] : []
  }
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  #expect(try await client.shutdown(timeout: .milliseconds(200)))
  #expect(backend.forceStopped)
}

@Test(.timeLimit(.minutes(1))) func shutdownReturnsFalseWhenThePersonKeepsWorking() async throws {
  let backend = ScriptedBackend { message in
    message["method"] == "shutdown" ? [#"{"id":1,"ok":true,"value":false}"#] : []
  }
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  #expect(try await client.shutdown(timeout: .milliseconds(200)) == false)
  #expect(!backend.forceStopped)
}

@Test(.timeLimit(.minutes(1))) func shutdownDoesNotForceStopABackendThatExits() async throws {
  let backend = ScriptedBackend { message in
    message["method"] == "shutdown" ? [#"{"id":1,"ok":true,"value":true}"#] : []
  }
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  let quitting = Task { try await client.shutdown(timeout: .seconds(10)) }
  try await waitFor { backend.messages.count == 1 }
  backend.close()
  #expect(try await quitting.value)
  #expect(!backend.forceStopped)
}

@Test(.timeLimit(.minutes(1))) func aChoiceThatNamesNoButtonCancels() async throws {
  let backend = ScriptedBackend { message in
    if message["method"] == "create" {
      return [#"{"ask":3,"kind":"confirm","title":"Trust this project?","message":"Work with Muse in “p”?","buttons":["Trust project","Cancel"]}"#]
    }
    if message["answer"] == 3 { return [#"{"id":1,"ok":true,"value":\#(viewJSON)}"#] }
    return []
  }
  let client = BackendClient(transport: backend, answerAsk: { _ in 7 })
  await client.run()
  _ = try await client.create(project: "/p")
  #expect(backend.messages.contains { $0 == ["answer": 3, "choice": -1] })
}

@Test(.timeLimit(.minutes(1))) func anUnreadableAskIsCancelled() async throws {
  let backend = ScriptedBackend()
  let client = BackendClient(transport: backend, answerAsk: { _ in 0 })
  await client.run()
  backend.push(#"{"ask":4,"kind":"confirm","title":"No buttons"}"#)
  var events = client.events.makeAsyncIterator()
  #expect(await events.next() == .error(BackendError.unreadable("An Ask could not be decoded.").localizedDescription))
  #expect(backend.messages == [["answer": 4, "choice": -1]])
}

@Test(.timeLimit(.minutes(1))) func badLinesBecomeErrorEvents() async throws {
  let backend = ScriptedBackend()
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  backend.push(#"{"id":1e300,"ok":true,"value":null}"#)
  backend.push("not JSON")
  var events = client.events.makeAsyncIterator()
  #expect(await events.next() == .error(BackendError.unreadable("A reply had an id that is not a whole number.").localizedDescription))
  #expect(await events.next() == .error(BackendError.unreadable("A line could not be decoded.").localizedDescription))
}

@Test func aReplyOfTheWrongShapeIsUnreadable() async throws {
  let backend = ScriptedBackend { _ in [#"{"id":1,"ok":true,"value":"not a hello"}"#] }
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  await #expect(throws: BackendError.unreadable("The hello reply did not match what mMac expects.")) {
    _ = try await client.hello()
  }
}

/// Polls `condition` until it holds. The test's time limit ends a wait that never does.
private func waitFor(_ condition: () -> Bool) async throws {
  while !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

@Test func lineSplitterJoinsALineSplitAcrossReads() {
  var splitter = LineSplitter()
  #expect(splitter.append(Data(#"{"a":1}"#.utf8) + Data([0x0A]) + Data(#"{"b""#.utf8)) == [Data(#"{"a":1}"#.utf8)])
  #expect(splitter.append(Data(#":2}"#.utf8) + Data([0x0A])) == [Data(#"{"b":2}"#.utf8)])
}

@Test(.timeLimit(.minutes(1))) func aCancelledRequestStopsWaitingAndIgnoresItsLateReply() async throws {
  let backend = ScriptedBackend()
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  let waiting = Task { try await client.sessions() }
  while backend.messages.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
  waiting.cancel()
  // The Reply to the cancelled request arrives a second later and must be ignored. If
  // cancelling stopped nothing, this Reply ends the wait, and the expectation fails, not hangs.
  let late = Task.detached {
    try await Task.sleep(for: .seconds(1))
    backend.push(#"{"id":1,"ok":true,"value":{"sessions":[],"nextCursor":null}}"#)
  }
  await #expect(throws: CancellationError.self) { _ = try await waiting.value }
  try await late.value
  let next = Task { try await client.sessions() }
  while backend.messages.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
  backend.push(#"{"id":2,"ok":true,"value":{"sessions":[],"nextCursor":null}}"#)
  #expect(try await next.value.sessions.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func forceStopStopsTheTransportAndFailsWaitingRequests() async throws {
  let backend = ScriptedBackend()
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  let waiting = Task { try await client.request("sessions") }
  try await waitFor { backend.messages.contains { $0["method"] == "sessions" } }
  client.forceStop()
  #expect(backend.forceStopped)
  await #expect(throws: BackendError.stopped) { try await waiting.value }
}

@Test(.timeLimit(.minutes(1))) func aRequestCancelledBeforeItStartsSendsNothing() async throws {
  let backend = ScriptedBackend()
  let client = BackendClient(transport: backend, answerAsk: { _ in -1 })
  await client.run()
  let task = Task {
    // Wait for the cancel below before the request starts.
    while !Task.isCancelled { await Task.yield() }
    return try await client.request("sessions")
  }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(backend.messages.isEmpty)
}
