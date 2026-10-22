import Foundation

/// Finds Node and starts the backend from a checkout of the fork.
public enum Launcher {
  /// Starts the backend in `repository`: by default `src/headless/server.ts`, or other Node
  /// `arguments` (the UI tests' fake backend). It reads the login shell's environment once, for up
  /// to 6 seconds, without blocking a thread, and passes it to the backend.
  public static func launch(
    repository: URL, arguments: [String] = ProcessTransport.serverArguments
  ) async throws -> ProcessTransport {
    let environment = backendEnvironment(
      own: ProcessInfo.processInfo.environment, login: await loginEnvironment(), shell: loginShell)
    let path = environment["PATH"] ?? ""
    guard let node = findNode(path: path) else {
      throw BackendError.backend(
        "mMac could not find Node on the PATH from your login shell. Install Node 22.12 or newer, "
          + "or check that your shell profile adds it to PATH, then restart mMac.")
    }
    return try ProcessTransport(
      executable: node, arguments: arguments, directory: repository, environment: environment)
  }

  /// The login shell's whole environment, read once. An app opened from Finder gets a short PATH
  /// without Node or muse, and the backend needs what the terminal has.
  static func loginEnvironment() async -> [String: String]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: loginShell)
    process.arguments = ["-ilc", #"printf '\0MMAC_ENV\0'; /usr/bin/env -0"#]
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    return await output(of: process, timeout: 6).flatMap(parseLoginEnvironment)
  }

  static var loginShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

  /// Runs `process` and returns its stdout once stdout closes, or after `timeout` seconds. No
  /// thread waits meanwhile.
  static func output(of process: Process, timeout: TimeInterval) async -> Data? {
    let pipe = Pipe()
    let state = OutputState()
    process.standardOutput = pipe
    process.terminationHandler = { _ in state.markExited() }
    return await withCheckedContinuation { continuation in
      state.replies(to: continuation)
      let reader = PipeReader(
        pipe.fileHandleForReading, received: { state.append($0) }, ended: { state.finish() })
      do { try process.run() } catch {
        // Reply before `end()`, whose `ended` would otherwise reply with empty data.
        state.giveUp()
        reader.end()
        try? pipe.fileHandleForWriting.close()
        return
      }
      let pid = process.processIdentifier
      // At the deadline, a process still running is killed with SIGKILL, because an interactive
      // shell ignores SIGTERM, and the reply is nil. The kill applies even after a reply: a shell
      // that closed stdout but still runs is killed too. A process that exited while a child it
      // started (such as a daemon from a shell's start-up files) holds stdout open replies with
      // what was read by the deadline.
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if state.stillRunning {
          kill(pid, SIGKILL)
          state.giveUp()
        }
        reader.end()
      }
    }
  }

  /// The `KEY=VALUE` records after the `MMAC_ENV` marker. Shell start-up output before it is ignored.
  static func parseLoginEnvironment(_ data: Data) -> [String: String]? {
    let marker = Data([0]) + Data("MMAC_ENV".utf8) + Data([0])
    guard let range = data.range(of: marker) else { return nil }
    var environment: [String: String] = [:]
    for record in data[range.upperBound...].split(separator: 0) {
      let text = String(decoding: record, as: UTF8.self)
      guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
      environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
    }
    return environment.isEmpty ? nil : environment
  }

  /// mMac's own environment, without what Xcode injects, with the login shell's on top. Shell
  /// bookkeeping variables are left out. With a login environment, `MMAC_LOGIN_SHELL` tells the
  /// backend it need not read the shell again.
  static func backendEnvironment(own: [String: String], login: [String: String]?, shell: String) -> [String: String] {
    // Xcode's debug launches inject DYLD_ variables and NODE_OPTIONS, which Node must not inherit.
    // An inherited MMAC_LOGIN_SHELL must not survive a failed login read.
    let dropped: Set<String> = ["NODE_OPTIONS", "MMAC_LOGIN_SHELL", "_", "SHLVL", "PWD", "OLDPWD"]
    let keep = { (key: String) in !key.hasPrefix("DYLD_") && !dropped.contains(key) }
    var environment = own.filter { keep($0.key) }
    for (key, value) in login ?? [:] where keep(key) { environment[key] = value }
    // The login shell's PATH comes first, so the backend uses the same tools as the terminal.
    environment["PATH"] = mergePaths([
      login?["PATH"], own["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
    ])
    if login != nil { environment["MMAC_LOGIN_SHELL"] = shell }
    return environment
  }

  /// Joins PATH lists, keeping the first copy of each folder.
  static func mergePaths(_ paths: [String?]) -> String {
    var seen = Set<String>()
    var result: [String] = []
    for folder in paths.compactMap({ $0 }).flatMap({ $0.split(separator: ":").map(String.init) })
    where seen.insert(folder).inserted {
      result.append(folder)
    }
    return result.joined(separator: ":")
  }

  static func findNode(
    path: String, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
  ) -> URL? {
    for folder in path.split(separator: ":") where isExecutable("\(folder)/node") {
      return URL(fileURLWithPath: "\(folder)/node")
    }
    return nil
  }
}

/// What `Launcher.output` has read, and its one reply.
private final class OutputState: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var exited = false
  private var replied = false
  private var continuation: CheckedContinuation<Data?, Never>?

  /// Set before the process starts, so before any handler can reply.
  func replies(to continuation: CheckedContinuation<Data?, Never>) {
    lock.withLock { self.continuation = continuation }
  }

  func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
  func markExited() { lock.withLock { exited = true } }
  var stillRunning: Bool { lock.withLock { !exited } }

  /// stdout ended, or the deadline passed with the process gone: reply with what was read.
  func finish() { reply(lock.withLock { data }) }
  /// The process could not start, or was killed at the deadline.
  func giveUp() { reply(nil) }

  private func reply(_ value: Data?) {
    let waiting = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
      guard !replied else { return nil }
      replied = true
      return continuation
    }
    waiting?.resume(returning: value)
  }
}
