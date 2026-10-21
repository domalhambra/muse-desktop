import Foundation

/// Finds Node and starts the backend from a checkout of the fork.
public enum Launcher {
  /// Starts `src/headless/server.ts` in `repository`. Blocks for up to 6 seconds while it reads
  /// the login shell's PATH, so call it off the main actor.
  public static func launch(repository: URL) throws -> ProcessTransport {
    var environment = ProcessInfo.processInfo.environment
    let path = mergePaths([
      environment["PATH"], loginPath(), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
    ])
    environment["PATH"] = path
    guard let node = findNode(path: path) else {
      throw BackendError.backend("mMac could not find Node. Install Node 22.12 or newer, then restart mMac.")
    }
    return try ProcessTransport(node: node, repository: repository, environment: environment)
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
    final class Collected: @unchecked Sendable {
      private let lock = NSLock()
      private var data = Data()
      func append(_ more: Data) { lock.withLock { data.append(more) } }
      var value: Data { lock.withLock { data } }
    }
    let pipe = Pipe()
    let collected = Collected()
    let closed = DispatchSemaphore(value: 0)
    process.standardOutput = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        closed.signal()
      } else {
        collected.append(data)
      }
    }
    do { try process.run() } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return nil
    }
    if closed.wait(timeout: .now() + timeout) == .timedOut {
      pipe.fileHandleForReading.readabilityHandler = nil
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        return nil
      }
    }
    return collected.value
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
