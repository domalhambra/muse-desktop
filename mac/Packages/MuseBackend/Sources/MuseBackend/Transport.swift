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
  private let errorEnded = OneShot()

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
    let ended = errorEnded
    errorReader = PipeReader(
      errors.fileHandleForReading,
      received: { data in
        // `write(_:)` raises an Objective-C exception on a closed pipe; this throws instead.
        try? FileHandle.standardError.write(contentsOf: data)
        tail.append(data)
      },
      ended: { ended.fire() })
    process.standardError = errors
    // A write to a backend that has exited must throw, not end mMac with SIGPIPE. Only mMac's
    // own pipe to the backend's stdin is marked. fd 2 is left alone: other writers share it.
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    do { try process.run() } catch {
      stdout.end()
      errorReader.end()
      throw error
    }
  }

  /// Up to the last 4,000 bytes the child wrote to stderr, trimmed, once stderr has ended. A
  /// grandchild can hold stderr open after the child exits, so this waits at most `limit`.
  public func errorOutput(waitingUpTo limit: Duration = .seconds(1)) async -> String {
    let ended = errorEnded
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await ended.wait() }
      group.addTask { try? await Task.sleep(for: limit) }
      await group.next()
      group.cancelAll()
    }
    return errorTail.text
  }

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
      // A copy, not `removeFirst`: a slice keeps every byte it ever held.
      if data.count > limit { data = Data(data.suffix(limit)) }
    }
  }

  /// The buffer's first index, so a test can check that the buffer is a copy, not a slice.
  var bufferStartIndex: Int { lock.withLock { data.startIndex } }

  /// The kept bytes as text. A cut can fall inside a character, so the text starts after any
  /// leading UTF-8 continuation bytes (0x80 to 0xBF), and never with U+FFFD.
  var text: String {
    lock.withLock {
      let start = data.firstIndex { $0 & 0xC0 != 0x80 } ?? data.endIndex
      return String(decoding: data[start...], as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
}

/// Fires once. Waiters resume when it fires or when their task is cancelled.
final class OneShot: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  func fire() {
    let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      guard !fired else { return [] }
      fired = true
      defer { waiters = [:] }
      return Array(waiters.values)
    }
    for waiter in waiting { waiter.resume() }
  }

  func wait() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let resumeNow = lock.withLock { () -> Bool in
          if fired || Task.isCancelled { return true }
          waiters[id] = continuation
          return false
        }
        if resumeNow { continuation.resume() }
      }
    } onCancel: {
      lock.withLock { waiters.removeValue(forKey: id) }?.resume()
    }
  }
}
