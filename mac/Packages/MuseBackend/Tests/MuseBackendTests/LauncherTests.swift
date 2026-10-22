import Foundation
import Testing
@testable import MuseBackend

@Test func parseLoginEnvironmentSkipsShellNoise() {
  // Separate parts: one long `+` chain is too slow for the type checker.
  let records = ["motd\n", "MMAC_ENV", "PATH=/opt/bin:/usr/bin", "EMPTY=", "EQUALS=a=b"]
  let output = Data(records.joined(separator: "\0").utf8) + Data([0])
  #expect(Launcher.parseLoginEnvironment(output) == ["PATH": "/opt/bin:/usr/bin", "EMPTY": "", "EQUALS": "a=b"])
  #expect(Launcher.parseLoginEnvironment(Data("no marker".utf8)) == nil)
}

@Test func theBackendEnvironmentLayersTheLoginShellOverMMac() {
  let environment = Launcher.backendEnvironment(
    own: ["PATH": "/usr/bin", "HOME": "/h", "DYLD_X": "1", "NODE_OPTIONS": "--x", "KEEP": "own"],
    login: ["PATH": "/opt/node/bin", "LANG": "en_US.UTF-8", "SHLVL": "2", "_": "/bin/env", "PWD": "/x", "KEEP": "login"],
    shell: "/bin/zsh")
  #expect(environment["PATH"] == "/opt/node/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin")
  #expect(environment["LANG"] == "en_US.UTF-8")
  #expect(environment["KEEP"] == "login")
  #expect(environment["HOME"] == "/h")
  #expect(environment["MMAC_LOGIN_SHELL"] == "/bin/zsh")
  for gone in ["DYLD_X", "NODE_OPTIONS", "SHLVL", "_", "PWD"] { #expect(environment[gone] == nil) }
  let withoutLogin = Launcher.backendEnvironment(own: ["PATH": "/usr/bin"], login: nil, shell: "/bin/zsh")
  #expect(withoutLogin["MMAC_LOGIN_SHELL"] == nil)
  #expect(withoutLogin["PATH"] == "/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin")
}

@Test func mergePathsKeepsTheFirstCopyOfEachFolder() {
  #expect(Launcher.mergePaths(["/a:/b", nil, "/b::/c"]) == "/a:/b:/c")
}

@Test func findNodeReturnsTheFirstExecutableNode() {
  let found = Launcher.findNode(path: "/x:/y:/z", isExecutable: { $0 == "/y/node" || $0 == "/z/node" })
  #expect(found == URL(fileURLWithPath: "/y/node"))
  #expect(Launcher.findNode(path: "/x", isExecutable: { _ in false }) == nil)
}

/// A `/bin/sh` process for `Launcher.output`, which `loginEnvironment` uses to read the login shell.
private func shell(_ script: String) -> Process {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", script]
  process.environment = ["PATH": "/usr/bin:/bin"]
  return process
}

@Test(.timeLimit(.minutes(1))) func outputGivesUpOnAShellThatIgnoresSIGTERM() async {
  // An interactive login shell ignores SIGTERM, so the deadline must use SIGKILL.
  let start = ContinuousClock.now
  #expect(await Launcher.output(of: shell(#"trap "" TERM; while :; do sleep 1; done"#), timeout: 1) == nil)
  #expect(ContinuousClock.now - start < .seconds(3))
}

@Test(.timeLimit(.minutes(1))) func outputReturnsWhatAShellPrintedWhenAChildHoldsItsStdout() async {
  // A daemon started from a shell's start-up files can keep stdout open after the shell exits.
  #expect(await Launcher.output(of: shell("printf done; sleep 2 &"), timeout: 1) == Data("done".utf8))
}

@Test(.timeLimit(.minutes(1))) func outputReturnsAtEOFWithoutWaitingForTheDeadline() async {
  let start = ContinuousClock.now
  #expect(await Launcher.output(of: shell("printf quick"), timeout: 5) == Data("quick".utf8))
  #expect(ContinuousClock.now - start < .seconds(2))
}
