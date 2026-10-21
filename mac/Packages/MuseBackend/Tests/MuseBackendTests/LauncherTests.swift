import Foundation
import Testing
@testable import MuseBackend

@Test func parseLoginPathSkipsShellNoise() {
  let output = Data("Last login: today\n".utf8) + Data([0]) + Data("MMAC_PATH".utf8) + Data([0])
    + Data("/opt/homebrew/bin:/usr/bin".utf8)
  #expect(Launcher.parseLoginPath(output) == "/opt/homebrew/bin:/usr/bin")
  #expect(Launcher.parseLoginPath(Data("no marker".utf8)) == nil)
}

@Test func mergePathsKeepsTheFirstCopyOfEachFolder() {
  #expect(Launcher.mergePaths(["/a:/b", nil, "/b::/c"]) == "/a:/b:/c")
}

@Test func findNodeReturnsTheFirstExecutableNode() {
  let found = Launcher.findNode(path: "/x:/y:/z", isExecutable: { $0 == "/y/node" || $0 == "/z/node" })
  #expect(found == URL(fileURLWithPath: "/y/node"))
  #expect(Launcher.findNode(path: "/x", isExecutable: { _ in false }) == nil)
}

/// A `/bin/sh` process for `Launcher.output`, which `loginPath` uses to read the login shell.
private func shell(_ script: String) -> Process {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", script]
  process.environment = ["PATH": "/usr/bin:/bin"]
  return process
}

@Test(.timeLimit(.minutes(1))) func outputGivesUpOnAShellThatIgnoresSIGTERM() {
  // An interactive login shell ignores SIGTERM, so the deadline must use SIGKILL.
  let start = ContinuousClock.now
  #expect(Launcher.output(of: shell(#"trap "" TERM; while :; do sleep 1; done"#), timeout: 1) == nil)
  #expect(ContinuousClock.now - start < .seconds(3))
}

@Test(.timeLimit(.minutes(1))) func outputReturnsWhatAShellPrintedWhenAChildHoldsItsStdout() {
  // A daemon started from a shell's start-up files can keep stdout open after the shell exits.
  #expect(Launcher.output(of: shell("printf done; sleep 2 &"), timeout: 1) == Data("done".utf8))
}
