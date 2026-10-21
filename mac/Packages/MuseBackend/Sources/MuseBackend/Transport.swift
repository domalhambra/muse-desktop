import Foundation

/// A line-based link to the backend.
public protocol Transport: Sendable {
  /// Lines from the backend, without their newline. The stream finishes when the backend stops.
  var lines: AsyncStream<Data> { get }
  /// Sends one line. The transport adds the newline.
  func send(_ line: Data) throws
  /// Ends the backend's input. The backend then quits on its own.
  func close()
  /// Stops a backend that did not quit in time.
  func forceStop()
}
