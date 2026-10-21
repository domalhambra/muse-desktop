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
public final class ProcessTransport: Transport, Sendable {
  public let lines: AsyncStream<Data>
  private let process = Process()
  private let input = Pipe()
  private let stdout: PipeReader
  private let errorReader: PipeReader
  private let errorTail = ErrorTail()

  /// The Node arguments that start mMac's backend.
  public static let serverArguments = ["--import", "tsx", "src/headless/server.ts"]

  /// Starts `src/headless/server.ts` under `node`, in `repository`.
  public convenience init(node: URL, repository: URL, environment: [String: String]) throws {
    try self.init(
      executable: node, arguments: Self.serverArguments, directory: repository,
      environment: environment)
  }

  /// Starts any executable. Tests use it to run `/bin/sh` in place of Node.
  public init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws {
    // A write to a backend that has exited must throw, not end mMac with SIGPIPE.
    signal(SIGPIPE, SIG_IGN)
    let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    lines = stream
    let output = Pipe()
    var splitter = LineSplitter()
    stdout = PipeReader(
      output.fileHandleForReading,
      received: { data in
        for line in splitter.append(data) { continuation.yield(line) }
      },
      ended: { continuation.finish() })
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    let errors = Pipe()
    let tail = errorTail
    errorReader = PipeReader(
      errors.fileHandleForReading,
      received: { data in
        FileHandle.standardError.write(data)
        tail.append(data)
      },
      ended: {})
    process.standardError = errors
    do { try process.run() } catch {
      stdout.end()
      errorReader.end()
      throw error
    }
  }

  /// Up to the last 4,000 bytes the child wrote to stderr, trimmed.
  public var recentErrorOutput: String { errorTail.text }

  public func send(_ line: Data) throws {
    try input.fileHandleForWriting.write(contentsOf: line + Data([0x0A]))
  }

  public func close() {
    try? input.fileHandleForWriting.close()
  }

  /// Sends SIGTERM, then SIGKILL after 2 seconds, and then ends `lines`. When `waitForExit`
  /// calls it, the backend is usually already quitting and ignores SIGTERM, so the SIGKILL does
  /// the work. It ends `lines` itself because a grandchild can hold stdout open after the child
  /// is gone, so the pipe may never reach EOF.
  public func forceStop() {
    let stdout = self.stdout
    let errorReader = self.errorReader
    guard process.isRunning else {
      stdout.end()
      errorReader.end()
      return
    }
    process.terminate()
    let process = self.process
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      stdout.end()
      errorReader.end()
    }
  }
}

/// Reads a pipe on its background queue until EOF or `end()`, whichever comes first, then clears
/// the handler, closes the read end and calls `ended` once. `received` and the close run under
/// one lock, so a read never meets a closed handle. `received` and `ended` run while the lock is
/// held, so they must not call `end()`.
final class PipeReader: @unchecked Sendable {
  private let lock = NSLock()
  private let handle: FileHandle
  private let received: (Data) -> Void
  private let ended: () -> Void
  private var isOpen = true

  init(_ handle: FileHandle, received: @escaping (Data) -> Void, ended: @escaping () -> Void) {
    self.handle = handle
    self.received = received
    self.ended = ended
    handle.readabilityHandler = { [self] _ in read() }
  }

  /// Stops reading and closes the read end. Safe to call more than once, from any thread.
  func end() { lock.withLock { endLocked() } }

  private func read() {
    lock.withLock {
      guard isOpen else { return }
      let data = handle.availableData
      if data.isEmpty { endLocked() } else { received(data) }
    }
  }

  private func endLocked() {
    guard isOpen else { return }
    isOpen = false
    handle.readabilityHandler = nil
    try? handle.close()
    ended()
  }
}

/// The last bytes a child wrote to stderr, for the setup screen.
final class ErrorTail: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private let limit = 4000

  func append(_ chunk: Data) {
    lock.withLock {
      data.append(chunk)
      if data.count > limit { data.removeFirst(data.count - limit) }
    }
  }

  var text: String {
    lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
  }
}
