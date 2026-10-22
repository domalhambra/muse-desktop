import Foundation

/// Finds Node and starts the backend from a checkout of the fork.
public enum Launcher {
  /// Starts the backend in `repository`: by default `src/headless/server.ts`, or other Node
  /// `arguments` (the UI tests' fake backend). It waits up to 6 seconds for the login shell's PATH,
  /// without blocking a thread.
  public static func launch(
    repository: URL, arguments: [String] = ProcessTransport.serverArguments
  ) async throws -> ProcessTransport {
    // Xcode's debug launches inject DYLD_ variables and NODE_OPTIONS, which Node must not inherit.
    var environment = ProcessInfo.processInfo.environment.filter {
      !$0.key.hasPrefix("DYLD_") && $0.key != "NODE_OPTIONS"
    }
    // The login shell's PATH comes first, so the backend uses the same tools as the terminal.
    let path = mergePaths([
      await loginPath(), environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
    ])
    environment["PATH"] = path
    guard let node = findNode(path: path) else {
      throw BackendError.backend(
        "mMac could not find Node on the PATH from your login shell. Install Node 22.12 or newer, "
          + "or check that your shell profile adds it to PATH, then restart mMac.")
    }
    return try ProcessTransport(
      executable: node, arguments: arguments, directory: repository, environment: environment)
  }

  /// The login shell's PATH. An app opened from Finder gets a short PATH without Node or muse.
  static func loginPath() async -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-ilc", #"printf '\0MMAC_PATH\0%s' "$PATH""#]
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    return await output(of: process, timeout: 6).flatMap(parseLoginPath)
  }

  /// Runs `process` and returns its stdout once stdout closes, or after `timeout` seconds.
  /// It returns nil if the process is still running then, and kills it with SIGKILL, because an
  /// interactive shell ignores SIGTERM. A child the process started, such as a daemon from a
  /// shell's start-up files, can hold stdout open after the process exits. That case returns
  /// what was read by the deadline. No thread waits meanwhile.
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
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        // Still running at the deadline: kill it and return nil. Exited, but a child holds
        // stdout: return what was read.
        // The kill applies even after a reply: a shell that closed stdout but still runs is killed.
        if state.stillRunning {
          kill(pid, SIGKILL)
          state.giveUp()
        }
        reader.end()
      }
    }
  }

  /// The text after the `MMAC_PATH` marker. Shell start-up output before it is ignored.
  static func parseLoginPath(_ data: Data) -> String? {
    let marker = Data([0]) + Data("MMAC_PATH".utf8) + Data([0])
    guard let range = data.range(of: marker) else { return nil }
    let value = String(decoding: data[range.upperBound...], as: UTF8.self)
    return value.isEmpty ? nil : value
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
