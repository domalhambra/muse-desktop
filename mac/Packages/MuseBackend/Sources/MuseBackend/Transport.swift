import Foundation

/// A line-based link to the backend.
public protocol Transport: Sendable {
  /// Lines from the backend, without their newline. The stream finishes when the backend stops.
  var lines: AsyncStream<Data> { get }
  /// Sends one line. The transport adds the newline.
  func send(_ line: Data) throws
  /// Ends the backend's input. The backend then quits on its own.
  func close()
  /// Stops a backend that did not quit in time. It must end `lines`, or `waitForExit` waits forever.
  func forceStop()
}

/// Runs a child process and speaks lines over its stdin and stdout. mMac runs
/// `node --import tsx src/headless/server.ts` in a checkout of the fork.
public final class ProcessTransport: Transport, @unchecked Sendable {
  public let lines: AsyncStream<Data>
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()

  /// Splits stdout into lines. The pipe's handler runs on a background queue.
  private final class Reader: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()
    func append(_ data: Data) -> [Data] { lock.withLock { splitter.append(data) } }
  }

  /// Starts `src/headless/server.ts` under `node`, in `repository`.
  public convenience init(node: URL, repository: URL, environment: [String: String]) throws {
    try self.init(
      executable: node, arguments: ["--import", "tsx", "src/headless/server.ts"], directory: repository,
      environment: environment)
  }

  /// Starts any executable. Tests use it to run `/bin/sh` in place of Node.
  public init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws {
    // A write to a backend that has exited must throw, not end mMac with SIGPIPE.
    signal(SIGPIPE, SIG_IGN)
    let stream = AsyncStream.makeStream(of: Data.self)
    lines = stream.stream
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    let reader = Reader()
    let continuation = stream.continuation
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        continuation.finish()
        return
      }
      for line in reader.append(data) { continuation.yield(line) }
    }
    try process.run()
  }

  public func send(_ line: Data) throws {
    try input.fileHandleForWriting.write(contentsOf: line + Data([0x0A]))
  }

  public func close() {
    try? input.fileHandleForWriting.close()
  }

  /// Sends SIGTERM, which runs the backend's normal quit path, then SIGKILL after 2 seconds.
  /// Either signal closes the child's stdout, and the readability handler then ends `lines`.
  public func forceStop() {
    guard process.isRunning else { return }
    process.terminate()
    let process = self.process
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }
}
