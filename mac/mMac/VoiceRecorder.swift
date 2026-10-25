import AVFoundation
import MuseKit
import Synchronization

/// The microphone for voice input: an `AVAudioEngine` input tap that keeps mono samples and
/// meters them, as Electron's `MediaRecorder` and `AnalyserNode` do. `VoiceSession` asks for the
/// permission first, and turns the recording into the WAV the CLI transcribes.
@MainActor
final class VoiceRecorder: VoiceCapture {
  private var engine: AVAudioEngine?
  private var recording: SampleBuffer?
  private var onLevels: (@MainActor ([Double]) -> Void)?
  private var onFailed: (@MainActor () -> Void)?
  /// Watches for the input going away mid-recording, such as a headset unplugged.
  private var configurationObserver: (any NSObjectProtocol)?

  func requestPermission() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  func start(levels: @escaping @MainActor ([Double]) -> Void, failed: @escaping @MainActor () -> Void) throws {
    end()
    // A refusal made in System Settings after the first ask.
    guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else {
      throw WorkspaceError(VoiceSession.microphoneOff)
    }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    // No input device, or one macOS has not opened.
    guard format.sampleRate > 0, format.channelCount > 0 else { throw WorkspaceError(VoiceSession.couldNotStart) }
    // The audio thread reports here; the bars reach the session on the main actor.
    let recording = SampleBuffer(sampleRate: format.sampleRate) { [weak self] bars in
      let recorder = self
      Task { @MainActor [recorder] in recorder?.deliver(bars) }
    }
    input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(into: recording))
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw WorkspaceError(VoiceSession.couldNotStart)
    }
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.inputStopped() }
    }
    self.engine = engine
    self.recording = recording
    onLevels = levels
    onFailed = failed
  }

  func stop() async throws -> VoiceRecording {
    let recorded = recording
    end()
    guard let recorded else { return VoiceRecording(samples: [], sampleRate: 0) }
    return VoiceRecording(samples: [recorded.samples()], sampleRate: recorded.sampleRate)
  }

  /// Safe at any time: before `start` (a cancel while macOS asks for the microphone), and around
  /// a `stop()`, which takes the recording before any await, so a cancel finds nothing left to drop.
  func cancel() { end() }

  /// Bars that arrive after a stop are dropped.
  private func deliver(_ bars: [Double]) {
    guard engine != nil else { return }
    onLevels?(bars)
  }

  private func inputStopped() {
    guard engine != nil else { return }
    let failed = onFailed
    end()
    failed?()
  }

  private func end() {
    if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    configurationObserver = nil
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    recording = nil
    onLevels = nil
    onFailed = nil
  }

  /// Made outside the main actor: AVAudioEngine calls the tap on its own audio thread, and a
  /// closure made in a main-actor method would assert the main actor there.
  nonisolated private static func tap(into recording: SampleBuffer) -> AVAudioNodeTapBlock {
    { buffer, _ in recording.append(buffer) }
  }
}

/// The tap's samples, shared with the audio thread. The lock guards both arrays.
final class SampleBuffer: Sendable {
  let sampleRate: Double
  /// Samples per meter report: 120 ms.
  private let meterLength: Int
  private let report: @Sendable ([Double]) -> Void
  private let state = Mutex(State())

  private struct State {
    var samples: [Float] = []
    /// The samples since the meter last reported.
    var pending: [Float] = []
  }

  init(sampleRate: Double, report: @escaping @Sendable ([Double]) -> Void) {
    self.sampleRate = sampleRate
    meterLength = max(Int(sampleRate * VoiceMeter.interval), 1)
    self.report = report
    // Room for the two-minute limit, so a long recording does not copy its samples as it grows.
    state.withLock { $0.samples.reserveCapacity(Int(sampleRate) * VoiceWAV.maxSeconds) }
  }

  /// Adds one tap buffer, averaged to mono, and reports the five bars each time 120 ms have gathered.
  func append(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frames > 0, channelCount > 0 else { return }
    let interleaved = buffer.format.isInterleaved
    var mono = [Float](repeating: 0, count: frames)
    for channel in 0..<channelCount {
      let data = interleaved ? channels[0] : channels[channel]
      for frame in 0..<frames {
        mono[frame] += data[interleaved ? frame * channelCount + channel : frame]
      }
    }
    if channelCount > 1 {
      let scale = 1 / Float(channelCount)
      for frame in 0..<frames { mono[frame] *= scale }
    }
    let meterLength = self.meterLength
    let bars: [Double]? = state.withLock { state in
      state.samples.append(contentsOf: mono)
      state.pending.append(contentsOf: mono)
      guard state.pending.count >= meterLength else { return nil }
      let bars = VoiceMeter.levels(state.pending)
      state.pending.removeAll(keepingCapacity: true)
      return bars
    }
    // Outside the lock.
    if let bars { report(bars) }
  }

  /// Every sample so far, mono.
  func samples() -> [Float] { state.withLock { $0.samples } }
}
