import Foundation

/// Finds Node and starts the backend from a checkout of the fork.
public enum Launcher {
  /// Starts the backend in `repository`: by default `src/headless/server.ts`, or other Node
  /// `arguments` (the UI tests' fake backend). Blocks for up to 6 seconds while it reads the login
  /// shell's PATH, so call it off the main actor.
  public static func launch(
    repository: URL, arguments: [String] = ProcessTransport.serverArguments
  ) throws -> ProcessTransport {
    // Xcode's debug launches inject DYLD_ variables and NODE_OPTIONS, which Node must not inherit.
    var environment = ProcessInfo.processInfo.environment.filter {
      !$0.key.hasPrefix("DYLD_") && $0.key != "NODE_OPTIONS"
    }
    // The login shell's PATH comes first, so the backend uses the same tools as the terminal.
    let path = mergePaths([
      loginPath(), environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
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
  static func loginPath() -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-ilc", #"printf '\0MMAC_PATH\0%s' "$PATH""#]
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    return output(of: process, timeout: 6).flatMap(parseLoginPath)
  }

  /// Runs `process` and returns its stdout once stdout closes, or after `timeout` seconds.
  /// It returns nil if the process is still running then, and kills it with SIGKILL, because an
  /// interactive shell ignores SIGTERM. A child the process started, such as a daemon from a
  /// shell's start-up files, can hold stdout open after the process exits. That case returns
  /// what was read by the deadline.
  static func output(of process: Process, timeout: TimeInterval) -> Data? {
    let pipe = Pipe()
    var data = Data()
    let closed = DispatchSemaphore(value: 0)
    let reader = PipeReader(
      pipe.fileHandleForReading, received: { data.append($0) }, ended: { closed.signal() })
    process.standardOutput = pipe
    do { try process.run() } catch {
      reader.end()
      try? pipe.fileHandleForWriting.close()
      return nil
    }
    let reachedEOF = closed.wait(timeout: .now() + timeout) == .success
    // After `end()` no handler runs, so `data` is safe to read.
    reader.end()
    if !reachedEOF, process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      return nil
    }
    return data
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
