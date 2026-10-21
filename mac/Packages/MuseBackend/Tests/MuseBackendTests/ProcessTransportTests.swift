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
  // The child prints "ready" once its trap is set, so SIGTERM cannot arrive before it.
  let transport = try shell(#"trap "" TERM; echo ready; while :; do sleep 1; done"#)
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

@Test(.timeLimit(.minutes(1))) func sendAfterTheChildExitsThrows() async throws {
  let transport = try shell("exit 0")
  for await _ in transport.lines {}
  #expect(throws: (any Error).self) { try transport.send(Data("late".utf8)) }
}
