import Foundation
import MuseBackend
import Observation

/// Mono 16 kHz 16-bit PCM WAV, the format `muse voice transcribe` takes. A port of
/// `encodeVoiceWav` in src/shared/voice.ts: the same downmix, resampling, limits and errors.
public enum VoiceWAV {
  public static let sampleRate = 16000
  public static let maxSeconds = 120
  /// `MAX_VOICE_BYTES`: the header and two minutes of samples.
  public static let maxBytes = 44 + sampleRate * maxSeconds * 2
  public static let unsupported = "The microphone returned an unsupported audio format."
  public static let tooShort = "Record at least a moment of speech and try again."
  public static let tooLong = "Voice recordings can be up to two minutes."

  /// Averages every channel to mono, takes the plain mean of each output sample's source span (no
  /// filter), clamps to [-1, 1], and scales by 32768 below zero and 32767 above. The length comes
  /// from the first channel; a shorter channel counts its missing samples as 0.
  public static func encode(samples channels: [[Float]], sampleRate: Double) throws -> Data {
    guard let first = channels.first, sampleRate.isFinite, sampleRate >= Double(Self.sampleRate) else {
      throw WorkspaceError(unsupported)
    }
    let length = Int((Double(first.count) * Double(Self.sampleRate) / sampleRate).rounded(.down))
    if length < Self.sampleRate / 5 { throw WorkspaceError(tooShort) }
    if length > Self.sampleRate * maxSeconds { throw WorkspaceError(tooLong) }
    var bytes = [UInt8](repeating: 0, count: 44 + length * 2)
    func text(_ offset: Int, _ value: String) {
      for (index, byte) in value.utf8.enumerated() { bytes[offset + index] = byte }
    }
    func uint32(_ offset: Int, _ value: Int) {
      for index in 0..<4 { bytes[offset + index] = UInt8((value >> (8 * index)) & 0xFF) }
    }
    func uint16(_ offset: Int, _ value: Int) {
      for index in 0..<2 { bytes[offset + index] = UInt8((value >> (8 * index)) & 0xFF) }
    }
    text(0, "RIFF")
    uint32(4, bytes.count - 8)
    text(8, "WAVE")
    text(12, "fmt ")
    uint32(16, 16)
    uint16(20, 1)
    uint16(22, 1)
    uint32(24, Self.sampleRate)
    uint32(28, Self.sampleRate * 2)
    uint16(32, 2)
    uint16(34, 16)
    text(36, "data")
    uint32(40, length * 2)
    let ratio = sampleRate / Double(Self.sampleRate)
    for index in 0..<length {
      let start = Int((Double(index) * ratio).rounded(.down))
      let end = min(first.count, Int((Double(index + 1) * ratio).rounded(.down)))
      var value = 0
      // JavaScript writes 0 for an empty span (NaN) and for a NaN mean; so does this.
      if end > start {
        var sum = 0.0
        for channel in channels {
          for sample in start..<end where sample < channel.count && !channel[sample].isNaN {
            sum += Double(channel[sample])
          }
        }
        let mean = sum / Double((end - start) * channels.count)
        if !mean.isNaN {
          let clamped = max(-1, min(1, mean))
          value = jsRound(clamped * (clamped < 0 ? 32768 : 32767))
        }
      }
      // The low 16 bits: two's complement for negative samples, as `setInt16`.
      uint16(44 + index * 2, value & 0xFFFF)
    }
    return Data(bytes)
  }

  /// `Math.round`: the nearest whole number, with halves toward positive infinity.
  static func jsRound(_ value: Double) -> Int {
    let floor = value.rounded(.down)
    return Int(value - floor >= 0.5 ? floor + 1 : floor)
  }
}

/// One recording: every channel's samples, at the device's rate.
public struct VoiceRecording: Equatable, Sendable {
  public let samples: [[Float]]
  public let sampleRate: Double

  public init(samples: [[Float]], sampleRate: Double) {
    self.samples = samples
    self.sampleRate = sampleRate
  }
}

/// The microphone. The app's `VoiceRecorder` records with `AVAudioEngine`; tests use a fake.
@MainActor
public protocol VoiceCapture: AnyObject {
  /// Asks macOS for the microphone. False when the person refused it.
  func requestPermission() async -> Bool
  /// Starts recording. `levels` gets the five bar heights about every 120 ms. `failed` is called
  /// when the input stops by itself. A refusal found only now should throw a `WorkspaceError` with
  /// `VoiceSession.microphoneOff`.
  func start(levels: @escaping @MainActor ([Double]) -> Void, failed: @escaping @MainActor () -> Void) throws
  /// Stops and returns what was recorded.
  func stop() async throws -> VoiceRecording
  /// Stops and drops the recording.
  func cancel()
}

/// Voice input, as Electron's `VoiceInput.tsx`: ask for the microphone, record, encode, then let
/// the Muse Code CLI transcribe the clip into the draft. Nothing is ever sent. Errors go to
/// `Workspace.errorMessage`, mMac's one error surface.
@MainActor @Observable
public final class VoiceSession {
  public enum Phase: Equatable, Sendable {
    case idle, permission, recording, transcribing
  }

  /// Electron stops at `MAX_VOICE_SECONDS - 1`, to leave room before the two-minute limit.
  public static let autoStopSeconds = VoiceWAV.maxSeconds - 1
  nonisolated public static let restingLevels: [Double] = [0.25, 0.45, 0.35, 0.5, 0.3]
  public static let microphoneOff =
    "Microphone access is off. Enable mMac in System Settings → Privacy & Security → Microphone."
  public static let couldNotStart = "Could not start your microphone."
  public static let stoppedRecording = "The microphone stopped recording. Check your input device and try again."
  /// The status pill's cancel button.
  public static let cancelLabel = "Cancel voice input"

  public private(set) var phase: Phase = .idle
  /// Whole seconds since recording started.
  public private(set) var elapsed = 0
  /// The five bar heights, each from 0.22 to 1.
  public private(set) var levels = VoiceSession.restingLevels

  private let workspace: Workspace
  private let capture: any VoiceCapture
  private let tickInterval: Duration
  private let uptime: @MainActor () -> TimeInterval
  @ObservationIgnored private var startedAt: TimeInterval = 0
  /// Bumped by every start and cancel, so a result for a recording the person dropped is ignored.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var timer: Task<Void, Never>?

  /// `tick` is Electron's 120 ms timer. `uptime` is the clock the time is read from; tests pass
  /// their own.
  public init(
    workspace: Workspace, capture: any VoiceCapture, tick: Duration = .milliseconds(120),
    uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.workspace = workspace
    self.capture = capture
    tickInterval = tick
    self.uptime = uptime
  }

  public var isBusy: Bool { phase != .idle }

  /// The mic button's label and tooltip.
  public var buttonLabel: String { phase == .recording ? "Stop recording (⌥V)" : "Voice input (⌥V)" }

  /// The status pill's text, or nil when idle.
  public var statusText: String? {
    switch phase {
    case .idle: nil
    case .permission: "Opening microphone…"
    case .recording: "Listening · \(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
    case .transcribing: "Transcribing with Muse…"
    }
  }

  /// The mic button, ⌥V and `/voice`: start when idle, stop and transcribe while recording.
  public func toggle() async {
    switch phase {
    case .idle: await start()
    case .recording: await stop()
    case .permission, .transcribing: break
    }
  }

  public func start() async {
    guard phase == .idle else { return }
    generation += 1
    let generation = self.generation
    phase = .permission
    let granted = await capture.requestPermission()
    guard generation == self.generation else { return }
    guard granted else {
      fail(Self.microphoneOff)
      return
    }
    do {
      try capture.start(
        levels: { [weak self] levels in self?.show(levels) },
        failed: { [weak self] in self?.captureFailed(generation) })
    } catch {
      let message = error.localizedDescription
      fail(message.isEmpty ? Self.couldNotStart : message)
      return
    }
    startedAt = uptime()
    elapsed = 0
    phase = .recording
    timer = Task { [weak self, tickInterval] in
      while !Task.isCancelled {
        try? await Task.sleep(for: tickInterval)
        guard let self, !Task.isCancelled else { return }
        self.tick()
      }
    }
  }

  /// Stops recording and transcribes. The text goes at the end of the draft.
  public func stop() async {
    guard phase == .recording else { return }
    let generation = self.generation
    stopTimer()
    phase = .transcribing
    do {
      let recording = try await capture.stop()
      guard generation == self.generation else { return }
      let client = workspace.client
      // Off the main actor: a two-minute clip at 48 kHz is almost six million samples.
      let text = try await Task.detached {
        let wav = try VoiceWAV.encode(samples: recording.samples, sampleRate: recording.sampleRate)
        let folder = try PrivateTemp.makeFolder("voice")
        // The backend deletes the file once read; the folder goes in every case.
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await client.voice(try PrivateTemp.write(wav, named: "recording.wav", in: folder))
      }.value
      guard generation == self.generation else { return }
      workspace.draft = Self.appending(text, to: workspace.draft)
      workspace.composerFocusRequest += 1
    } catch {
      guard generation == self.generation else { return }
      workspace.errorMessage = error.localizedDescription
    }
    reset()
  }

  /// Esc, the pill's cancel button, `/voice cancel`, and a hidden window: drop the recording or
  /// the transcription, with no message, as Electron's cancel.
  public func cancel() {
    guard phase != .idle else { return }
    generation += 1
    capture.cancel()
    reset()
    let client = workspace.client
    Task { try? await client.cancelVoice() }
  }

  /// Electron's append rule: at the end of the draft, after one space when the draft does not
  /// end in whitespace.
  nonisolated static func appending(_ text: String, to draft: String) -> String {
    draft + (draft.isEmpty || JSWhitespace.endsWithWhitespace(draft) ? "" : " ") + text
  }

  /// Every 120 ms while recording: the whole seconds, and the stop at 119.
  func tick() {
    guard phase == .recording else { return }
    elapsed = max(0, Int((uptime() - startedAt).rounded(.down)))
    if elapsed >= Self.autoStopSeconds { Task { await self.stop() } }
  }

  private func show(_ next: [Double]) {
    guard phase == .recording else { return }
    levels = (0..<5).map { index in
      index < next.count ? min(1, max(0.22, next[index])) : Self.restingLevels[index]
    }
  }

  private func captureFailed(_ generation: Int) {
    guard generation == self.generation, phase == .recording else { return }
    cancel()
    workspace.errorMessage = Self.stoppedRecording
  }

  private func fail(_ message: String) {
    reset()
    workspace.errorMessage = message
  }

  private func reset() {
    stopTimer()
    phase = .idle
    elapsed = 0
    levels = Self.restingLevels
  }

  private func stopTimer() {
    timer?.cancel()
    timer = nil
  }
}
