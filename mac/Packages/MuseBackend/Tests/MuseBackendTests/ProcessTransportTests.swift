import Foundation
import Testing
@testable import MuseBackend

/// Runs `script` under `/bin/sh`, so the real pipe and signal paths run without Node.
private func shell(_ script: String) throws -> ProcessTransport {
  try ProcessTransport(
    executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
    directory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
}

@Test(.timeLimit(.minutes(1))) func processTransportEchoesLinesInOrder() async throws {
  let transport = try shell(#"while IFS= read -r line; do printf "%s\n" "$line"; done"#)
  var lines = transport.lines.makeAsyncIterator()
  try transport.send(Data("one".utf8))
  try transport.send(Data("two".utf8))
  #expect(await lines.next() == Data("one".utf8))
  #expect(await lines.next() == Data("two".utf8))
  transport.close()
  #expect(await lines.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func forceStopEndsLinesWhenTheChildIgnoresSIGTERM() async throws {
  // The child prints "ready" once its trap is set, so SIGTERM cannot arrive before it. Its
  // `sleep` writes nowhere, so the stream cannot wait on a grandchild to exit.
  let transport = try shell(#"trap "" TERM; echo ready; while :; do sleep 1 >/dev/null; done"#)
  var lines = transport.lines.makeAsyncIterator()
  #expect(await lines.next() == Data("ready".utf8))
  let start = ContinuousClock.now
  transport.forceStop()
  #expect(await lines.next() == nil)
  let elapsed = ContinuousClock.now - start
  // SIGTERM was ignored, so it was SIGKILL, after 2 seconds, that ended the stream.
  #expect(elapsed >= .milliseconds(1500))
  #expect(elapsed < .seconds(5))
}

@Test(.timeLimit(.minutes(1))) func forceStopEndsLinesWhileAGrandchildHoldsStdout() async throws {
  // The background `sleep 30` inherits stdout, so the pipe stays open after the child is killed.
  let transport = try shell(#"trap "" TERM; sleep 30 & echo $!; while :; do sleep 1 >/dev/null; done"#)
  var lines = transport.lines.makeAsyncIterator()
  let line = try #require(await lines.next())
  let grandchild = try #require(pid_t(String(decoding: line, as: UTF8.self)))
  defer { kill(grandchild, SIGKILL) }
  let start = ContinuousClock.now
  transport.forceStop()
  #expect(await lines.next() == nil)
  #expect(ContinuousClock.now - start < .seconds(5))
}

@Test(.timeLimit(.minutes(1))) func sendAfterTheChildExitsThrows() async throws {
  // With SIGPIPE at its default, a write to the closed pipe would end this test process. The
  // transport must mark its own pipe instead of ignoring SIGPIPE for the whole process.
  signal(SIGPIPE, SIG_DFL)
  let transport = try shell("exit 0")
  for await _ in transport.lines {}
  #expect(throws: (any Error).self) { try transport.send(Data("late".utf8)) }
}

@Test(.timeLimit(.minutes(1))) func onlyTheBackendsPipeIsMarkedNotStderr() async throws {
  // fd 2 may be shared with other writers, so the transport leaves it as it found it. The flag
  // is cleared first, so a mark this process inherited cannot fail the test.
  _ = fcntl(FileHandle.standardError.fileDescriptor, F_SETNOSIGPIPE, 0)
  let before = fcntl(FileHandle.standardError.fileDescriptor, F_GETNOSIGPIPE)
  let transport = try shell("exit 0")
  for await _ in transport.lines {}
  #expect(fcntl(FileHandle.standardError.fileDescriptor, F_GETNOSIGPIPE) == before)
  #expect(before == 0)
}

@Test func stderrIsCopiedOnlyWhereAWriteCannotRaiseSIGPIPE() throws {
  let pipe = Pipe()
  #expect(!ProcessTransport.copyingIsSafe(to: pipe.fileHandleForWriting.fileDescriptor))
  let null = open("/dev/null", O_WRONLY)
  try #require(null >= 0)
  defer { close(null) }
  #expect(ProcessTransport.copyingIsSafe(to: null))
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data().write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  let handle = try FileHandle(forWritingTo: file)
  defer { try? handle.close() }
  #expect(ProcessTransport.copyingIsSafe(to: handle.fileDescriptor))
}

@Test(.timeLimit(.minutes(1))) func theTransportKeepsTheChildsLastErrorOutput() async throws {
  let transport = try shell(#"echo "first problem" >&2; echo "second problem" >&2; echo done"#)
  var lines = transport.lines.makeAsyncIterator()
  #expect(await lines.next() == Data("done".utf8))
  #expect(await lines.next() == nil)
  // stderr can lag stdout a little, so wait for it to end.
  let errors = await transport.errorOutput(waitingUpTo: .seconds(5))
  #expect(errors.contains("first problem"))
  #expect(errors.hasSuffix("second problem"))
}

@Test func theErrorTailStaysBoundedAndCopiesItsBuffer() {
  let tail = ErrorTail()
  let chunk = Data(repeating: UInt8(ascii: "x"), count: 1000)
  for _ in 0..<100 { tail.append(chunk) }
  #expect(tail.text.utf8.count <= 4000)
  // A buffer that only moved its start would keep every byte ever written.
  #expect(tail.bufferStartIndex == 0)
}

@Test func theErrorTailNeverStartsMidCharacter() {
  let tail = ErrorTail()
  // 6,001 bytes: keeping the last 4,000 cuts an "é" after its first byte.
  tail.append(Data((String(repeating: "é", count: 3000) + "z").utf8))
  #expect(!tail.text.contains("\u{FFFD}"))
  #expect(tail.text.hasPrefix("é"))
  #expect(tail.text.hasSuffix("z"))
}

@Test(.timeLimit(.minutes(1))) func errorOutputWaitsForStderrToEnd() async throws {
  // The child writes its last line to stderr after stdout has closed, as a crash trace can.
  let transport = try shell(#"exec 1>&-; sleep 0.3; echo "last words" >&2"#)
  for await _ in transport.lines {}
  let start = ContinuousClock.now
  #expect(await transport.errorOutput(waitingUpTo: .seconds(5)) == "last words")
  // Well below the 5-second limit: the end of stderr, not the limit, ended the wait.
  #expect(ContinuousClock.now - start < .seconds(2))
}

@Test(.timeLimit(.minutes(1))) func errorOutputStopsWaitingWhenAGrandchildHoldsStderr() async throws {
  // The background `sleep 30` redirects only stdout, so it keeps stderr open after the child
  // exits. Its pid comes first on stdout, so the test can kill it.
  let transport = try shell(#"echo "started" >&2; sleep 30 >/dev/null & echo $!; exit 0"#)
  var lines = transport.lines.makeAsyncIterator()
  let line = try #require(await lines.next())
  let grandchild = try #require(pid_t(String(decoding: line, as: UTF8.self)))
  defer { kill(grandchild, SIGKILL) }
  #expect(await lines.next() == nil)
  let start = ContinuousClock.now
  #expect(await transport.errorOutput(waitingUpTo: .milliseconds(300)) == "started")
  #expect(ContinuousClock.now - start < .seconds(2))
}
