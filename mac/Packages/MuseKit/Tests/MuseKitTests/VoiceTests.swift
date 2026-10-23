import Foundation
import MuseBackend
import MuseBackendTesting
import Synchronization
import Testing
@testable import MuseKit

// VoiceWAV: tests/unit/voice.test.ts, ported.

private func uint16(_ data: Data, _ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
private func int16(_ data: Data, _ offset: Int) -> Int { Int(Int16(bitPattern: UInt16(uint16(data, offset)))) }
private func uint32(_ data: Data, _ offset: Int) -> Int {
  (0..<4).reduce(0) { value, byte in value | Int(data[offset + byte]) << (8 * byte) }
}
private func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
  String(decoding: data[offset..<offset + count], as: UTF8.self)
}

@Test func stereoIsAveragedAndResampledTo16kHz() throws {
  let left = [Float](repeating: 0.75, count: 48000)
  let right = [Float](repeating: 0.25, count: 48000)
  let wav = try VoiceWAV.encode(samples: [left, right], sampleRate: 48000)
  #expect(wav.count == 44 + 16000 * 2)
  #expect(uint32(wav, 24) == 16000)
  // 0.5 × 32767 is 16383.5, and Math.round gives 16384.
  #expect(int16(wav, 44) == 16384)
}

@Test func theHeaderIsMono16BitPCMAt16kHz() throws {
  let wav = try VoiceWAV.encode(samples: [[Float](repeating: 0.1, count: 16000)], sampleRate: 16000)
  #expect(ascii(wav, 0, 4) == "RIFF")
  #expect(uint32(wav, 4) == wav.count - 8)
  #expect(ascii(wav, 8, 4) == "WAVE")
  #expect(ascii(wav, 12, 4) == "fmt ")
  #expect(uint32(wav, 16) == 16)
  #expect(uint16(wav, 20) == 1)
  #expect(uint16(wav, 22) == 1)
  #expect(uint32(wav, 24) == 16000)
  #expect(uint32(wav, 28) == 32000)
  #expect(uint16(wav, 32) == 2)
  #expect(uint16(wav, 34) == 16)
  #expect(ascii(wav, 36, 4) == "data")
  #expect(uint32(wav, 40) == 32000)
  #expect(VoiceWAV.maxBytes == 3_840_044)
}

@Test func samplesAreClippedAndRoundedAsJavaScriptRoundsThem() throws {
  let quiet = try VoiceWAV.encode(samples: [[Float](repeating: -2, count: 16000)], sampleRate: 16000)
  #expect(int16(quiet, 44) == -32768)
  let loud = try VoiceWAV.encode(samples: [[Float](repeating: 2, count: 16000)], sampleRate: 16000)
  #expect(int16(loud, 44) == 32767)
  // -3/65536 × 32768 is -1.5. Math.round gives -1; Swift's `rounded()` would give -2.
  let half = try VoiceWAV.encode(samples: [[Float](repeating: -3.0 / 65536, count: 16000)], sampleRate: 16000)
  #expect(int16(half, 44) == -1)
  // NaN counts as silence, as `channel[j] || 0` does.
  let silent = try VoiceWAV.encode(samples: [[Float](repeating: .nan, count: 16000)], sampleRate: 16000)
  #expect(int16(silent, 44) == 0)
  // A shorter second channel counts its missing samples as 0.
  let uneven = try VoiceWAV.encode(
    samples: [[Float](repeating: 0.5, count: 16000), [Float](repeating: 0.5, count: 10)], sampleRate: 16000)
  #expect(int16(uneven, 44) == 16384)
  #expect(int16(uneven, 44 + 2 * 100) == 8192)
}

@Test func shortLongAndOddClipsAreRefusedWithElectronsErrors() throws {
  #expect(throws: WorkspaceError("Record at least a moment of speech and try again.")) {
    try VoiceWAV.encode(samples: [[Float](repeating: 0, count: 50)], sampleRate: 16000)
  }
  #expect(throws: WorkspaceError("Record at least a moment of speech and try again.")) {
    try VoiceWAV.encode(samples: [[Float](repeating: 0, count: 3199)], sampleRate: 16000)
  }
  // 0.2 seconds is enough: 6444 bytes, the backend's smallest clip.
  #expect(try VoiceWAV.encode(samples: [[Float](repeating: 0, count: 3200)], sampleRate: 16000).count == 6444)
  #expect(throws: WorkspaceError("Voice recordings can be up to two minutes.")) {
    try VoiceWAV.encode(samples: [[Float](repeating: 0, count: 1_920_001)], sampleRate: 16000)
  }
  for rate in [8000, .nan, .infinity] as [Double] {
    #expect(throws: WorkspaceError("The microphone returned an unsupported audio format.")) {
      try VoiceWAV.encode(samples: [[Float](repeating: 0, count: 16000)], sampleRate: rate)
    }
  }
  #expect(throws: WorkspaceError("The microphone returned an unsupported audio format.")) {
    try VoiceWAV.encode(samples: [], sampleRate: 48000)
  }
}

// VoiceSession.

/// A microphone the test drives.
@MainActor
private final class FakeCapture: VoiceCapture {
  var granted = true
  /// When set, `requestPermission` waits until the test calls `allow(_:)`.
  var holdsPermission = false
  /// When set, `stop` waits until the test calls `finishStop()`.
  var holdsStop = false
  var startError: (any Error)?
  var stopError: (any Error)?
  var recording = VoiceRecording(samples: [[Float](repeating: 0.25, count: 16000)], sampleRate: 16000)
  private(set) var starts = 0
  private(set) var cancels = 0
  private var levels: (@MainActor ([Double]) -> Void)?
  private var failed: (@MainActor () -> Void)?
  private var permission: CheckedContinuation<Bool, Never>?
  private var stopping: CheckedContinuation<Void, Never>?
  var stopIsPending: Bool { stopping != nil }

  func requestPermission() async -> Bool {
    guard holdsPermission else { return granted }
    return await withCheckedContinuation { permission = $0 }
  }

  func allow(_ granted: Bool) {
    permission?.resume(returning: granted)
    permission = nil
  }

  func start(levels: @escaping @MainActor ([Double]) -> Void, failed: @escaping @MainActor () -> Void) throws {
    if let startError { throw startError }
    starts += 1
    self.levels = levels
    self.failed = failed
  }

  func stop() async throws -> VoiceRecording {
    if holdsStop { await withCheckedContinuation { stopping = $0 } }
    if let stopError { throw stopError }
    return recording
  }

  func finishStop() {
    stopping?.resume()
    stopping = nil
  }

  func cancel() { cancels += 1 }

  func send(_ values: [Double]) { levels?(values) }
  func fail() { failed?() }
}

@MainActor
private final class FakeUptime {
  var now: TimeInterval = 1000
}

/// What the backend saw of the clip when `voice` came: its path, size and modes.
private final class FileProbe: Sendable {
  struct Seen: Sendable {
    let path: String
    let size: Int
    let fileMode: Int
    let folderMode: Int
  }

  private let value = Mutex<Seen?>(nil)

  func record(_ path: String) {
    let manager = FileManager.default
    let file = try? manager.attributesOfItem(atPath: path)
    let folder = try? manager.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)
    let seen = Seen(
      path: path, size: (file?[.size] as? Int) ?? -1, fileMode: (file?[.posixPermissions] as? Int) ?? -1,
      folderMode: (folder?[.posixPermissions] as? Int) ?? -1)
    value.withLock { $0 = seen }
  }

  var seen: Seen? { value.withLock { $0 } }
}

/// A VoiceSession over a scripted backend. The timer is an hour apart, so tests call `tick()`.
@MainActor
private func makeVoice(
  draft: String = "", capture: FakeCapture? = nil,
  script: @escaping @Sendable (String, [JSONValue], Int) -> [String] = { method, _, id in
    method == "voice" ? [reply(id, #""A voice draft to review.""#)] : [reply(id, "null")]
  }
) async -> (VoiceSession, Workspace, ScriptedBackend, FakeCapture, FakeUptime) {
  let (workspace, backend) = await makeWorkspace(script: script)
  workspace.draft = draft
  let capture = capture ?? FakeCapture()
  let clock = FakeUptime()
  let voice = VoiceSession(workspace: workspace, capture: capture, tick: .seconds(3600), uptime: { clock.now })
  return (voice, workspace, backend, capture, clock)
}

private func lastId(_ backend: ScriptedBackend, _ method: String) -> Int? {
  guard case .number(let id)? = backend.messages.last(where: { $0["method"] == .string(method) })?["id"] else {
    return nil
  }
  return Int(id)
}

@MainActor @Test func recordingCountsTheTimeAndStopsItselfAt119Seconds() async throws {
  let (voice, workspace, backend, capture, clock) = await makeVoice()
  #expect(voice.buttonLabel == "Voice input (⌥V)")
  #expect(voice.statusText == nil)
  await voice.toggle()
  #expect(voice.phase == .recording)
  #expect(capture.starts == 1)
  #expect(voice.statusText == "Listening · 0:00")
  #expect(voice.buttonLabel == "Stop recording (⌥V)")
  clock.now = 1065.9
  voice.tick()
  #expect(voice.statusText == "Listening · 1:05")
  clock.now = 1118.9
  voice.tick()
  #expect(voice.phase == .recording)
  clock.now = 1119
  voice.tick()
  try await eventually { voice.phase == .idle }
  #expect(backend.messages.contains { $0["method"] == "voice" })
  #expect(workspace.draft == "A voice draft to review.")
}

@MainActor @Test func theTextGoesAtTheEndOfTheDraftAndIsNeverSent() async throws {
  let (voice, workspace, backend, _, _) = await makeVoice(draft: "Existing draft.")
  let focus = workspace.composerFocusRequest
  await voice.toggle()
  await voice.toggle()
  #expect(workspace.draft == "Existing draft. A voice draft to review.")
  #expect(workspace.composerFocusRequest == focus + 1)
  #expect(voice.phase == .idle)
  #expect(voice.elapsed == 0)
  #expect(!backend.messages.contains { $0["method"] == "send" })
}

@Test func theAppendRuleAddsOneSpaceOnlyWhenNeeded() {
  #expect(VoiceSession.appending("hi", to: "") == "hi")
  #expect(VoiceSession.appending("hi", to: "a") == "a hi")
  #expect(VoiceSession.appending("hi", to: "a ") == "a hi")
  #expect(VoiceSession.appending("hi", to: "a\n") == "a\nhi")
  #expect(VoiceSession.appending("hi", to: "a\u{00A0}") == "a\u{00A0}hi")
}

@MainActor @Test func theClipTravelsAsAPrivateFileThatIsDeletedAfter() async throws {
  let probe = FileProbe()
  let (voice, _, _, _, _) = await makeVoice { method, args, id in
    guard method == "voice" else { return [reply(id, "null")] }
    if case .string(let path)? = args.first { probe.record(path) }
    return [reply(id, #""text""#)]
  }
  await voice.toggle()
  await voice.toggle()
  let seen = try #require(probe.seen)
  #expect(seen.path.hasSuffix("/recording.wav"))
  #expect(seen.size == 44 + 16000 * 2)
  #expect(seen.fileMode == 0o600)
  #expect(seen.folderMode == 0o700)
  #expect(!FileManager.default.fileExists(atPath: seen.path))
  #expect(!FileManager.default.fileExists(atPath: (seen.path as NSString).deletingLastPathComponent))
}

@MainActor @Test func theStatusReadsOpeningMicrophoneWhileMacOSAsks() async throws {
  let capture = FakeCapture()
  capture.holdsPermission = true
  let (voice, _, _, _, _) = await makeVoice(capture: capture)
  let starting = Task { await voice.toggle() }
  try await eventually { voice.phase == .permission }
  #expect(voice.statusText == "Opening microphone…")
  #expect(voice.isBusy)
  // A cancel while macOS asks drops the answer that comes later.
  voice.cancel()
  capture.allow(true)
  await starting.value
  #expect(voice.phase == .idle)
  #expect(capture.starts == 0)
}

@MainActor @Test func aRefusedMicrophoneSaysWhereToTurnItOn() async throws {
  let capture = FakeCapture()
  capture.granted = false
  let (voice, workspace, _, _, _) = await makeVoice(capture: capture)
  await voice.toggle()
  #expect(voice.phase == .idle)
  #expect(capture.starts == 0)
  #expect(
    workspace.errorMessage
      == "Microphone access is off. Enable mMac in System Settings → Privacy & Security → Microphone.")
}

@MainActor @Test func aStartFailureShowsItsMessageOrTheGeneralOne() async throws {
  let capture = FakeCapture()
  capture.startError = WorkspaceError("The input device is busy.")
  let (voice, workspace, _, _, _) = await makeVoice(capture: capture)
  await voice.toggle()
  #expect(voice.phase == .idle)
  #expect(workspace.errorMessage == "The input device is busy.")
  capture.startError = WorkspaceError("")
  await voice.toggle()
  #expect(workspace.errorMessage == "Could not start your microphone.")
}

@MainActor @Test func aMicrophoneThatStopsCancelsWithItsMessage() async throws {
  let (voice, workspace, backend, capture, _) = await makeVoice()
  await voice.toggle()
  capture.fail()
  #expect(voice.phase == .idle)
  #expect(capture.cancels == 1)
  #expect(workspace.errorMessage == "The microphone stopped recording. Check your input device and try again.")
  #expect(!backend.messages.contains { $0["method"] == "voice" })
}

@MainActor @Test func cancellingWhileRecordingDropsTheClipQuietly() async throws {
  let (voice, workspace, backend, capture, _) = await makeVoice(draft: "Keep me.")
  await voice.toggle()
  voice.cancel()
  #expect(voice.phase == .idle)
  #expect(capture.cancels == 1)
  #expect(workspace.errorMessage == nil)
  try await eventually { backend.messages.contains { $0["method"] == "cancel-voice" } }
  #expect(!backend.messages.contains { $0["method"] == "voice" })
  #expect(workspace.draft == "Keep me.")
}

@MainActor @Test func cancellingWhileTranscribingDropsTheLateText() async throws {
  // `voice` gets no answer until the test pushes one.
  let (voice, workspace, backend, _, _) = await makeVoice(draft: "Keep me.") { method, _, id in
    method == "voice" ? [] : [reply(id, "null")]
  }
  await voice.toggle()
  let stopping = Task { await voice.toggle() }
  try await eventually { backend.messages.contains { $0["method"] == "voice" } }
  #expect(voice.phase == .transcribing)
  #expect(voice.statusText == "Transcribing with Muse…")
  voice.cancel()
  #expect(voice.phase == .idle)
  try await eventually { backend.messages.contains { $0["method"] == "cancel-voice" } }
  let id = try #require(lastId(backend, "voice"))
  backend.push(reply(id, #""late text""#))
  await stopping.value
  #expect(workspace.draft == "Keep me.")
  #expect(workspace.errorMessage == nil)
  #expect(voice.phase == .idle)
}

@MainActor @Test func aTranscriptionErrorShowsAndReturnsToIdle() async throws {
  let (voice, workspace, _, _, _) = await makeVoice(draft: "Draft.") { method, _, id in
    method == "voice"
      ? [failure(id, "Muse voice needs authentication. Run muse login in Terminal, then try again.")]
      : [reply(id, "null")]
  }
  await voice.toggle()
  await voice.toggle()
  #expect(voice.phase == .idle)
  #expect(workspace.errorMessage == "Muse voice needs authentication. Run muse login in Terminal, then try again.")
  #expect(workspace.draft == "Draft.")
}

@MainActor @Test func aTooShortClipFailsBeforeTheBackend() async throws {
  let capture = FakeCapture()
  capture.recording = VoiceRecording(samples: [[Float](repeating: 0, count: 100)], sampleRate: 16000)
  let (voice, workspace, backend, _, _) = await makeVoice(capture: capture)
  await voice.toggle()
  await voice.toggle()
  #expect(workspace.errorMessage == "Record at least a moment of speech and try again.")
  #expect(!backend.messages.contains { $0["method"] == "voice" })
  #expect(voice.phase == .idle)
}

@MainActor @Test func theBarsAreClampedAndRestWhenIdle() async throws {
  let (voice, _, _, capture, _) = await makeVoice()
  #expect(voice.levels == [0.25, 0.45, 0.35, 0.5, 0.3])
  await voice.toggle()
  capture.send([0.1, 2, 0.5, 0.3, 0.9])
  #expect(voice.levels == [0.22, 1, 0.5, 0.3, 0.9])
  capture.send([0.6])
  #expect(voice.levels == [0.6, 0.45, 0.35, 0.5, 0.3])
  voice.cancel()
  #expect(voice.levels == VoiceSession.restingLevels)
  #expect(VoiceSession.cancelLabel == "Cancel voice input")
}

@MainActor @Test func theFolderGoesAfterATranscriptionError() async throws {
  let probe = FileProbe()
  let (voice, _, _, _, _) = await makeVoice { method, args, id in
    guard method == "voice" else { return [reply(id, "null")] }
    if case .string(let path)? = args.first { probe.record(path) }
    return [failure(id, "Muse voice needs authentication. Run muse login in Terminal, then try again.")]
  }
  await voice.toggle()
  await voice.toggle()
  let seen = try #require(probe.seen)
  #expect(seen.fileMode == 0o600)
  #expect(!FileManager.default.fileExists(atPath: (seen.path as NSString).deletingLastPathComponent))
}

@MainActor @Test func theFolderGoesAfterACancelDuringTranscription() async throws {
  let probe = FileProbe()
  let (voice, _, backend, _, _) = await makeVoice { method, args, id in
    guard method == "voice" else { return [reply(id, "null")] }
    if case .string(let path)? = args.first { probe.record(path) }
    return []
  }
  await voice.toggle()
  let stopping = Task { await voice.toggle() }
  try await eventually { probe.seen != nil }
  let folder = (try #require(probe.seen).path as NSString).deletingLastPathComponent
  voice.cancel()
  try await eventually { backend.messages.contains { $0["method"] == "cancel-voice" } }
  let id = try #require(lastId(backend, "voice"))
  backend.push(reply(id, #""late text""#))
  await stopping.value
  try await eventually { !FileManager.default.fileExists(atPath: folder) }
}

@MainActor @Test func aToggleWhileTranscribingIsIgnored() async throws {
  let (voice, _, backend, _, _) = await makeVoice { method, _, id in
    method == "voice" ? [] : [reply(id, "null")]
  }
  await voice.toggle()
  let stopping = Task { await voice.toggle() }
  try await eventually { voice.phase == .transcribing && backend.messages.contains { $0["method"] == "voice" } }
  await voice.toggle()
  #expect(voice.phase == .transcribing)
  #expect(backend.messages.filter { $0["method"] == "voice" }.count == 1)
  let id = try #require(lastId(backend, "voice"))
  backend.push(reply(id, #""done""#))
  await stopping.value
  #expect(voice.phase == .idle)
}

/// A folder of the test's own, where the session makes its clip folder.
private func clipBase() throws -> URL {
  let base = FileManager.default.temporaryDirectory.appending(
    path: "mMac-voice-test-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
  return base
}

@MainActor @Test func aCancelWhileTheRecorderStopsSendsNothing() async throws {
  let capture = FakeCapture()
  capture.holdsStop = true
  let (voice, workspace, backend, _, _) = await makeVoice(draft: "Keep me.", capture: capture)
  let base = try clipBase()
  defer { try? FileManager.default.removeItem(at: base) }
  voice.temporaryFolder = base
  await voice.toggle()
  let stopping = Task { await voice.toggle() }
  try await eventually { capture.stopIsPending }
  voice.cancel()
  capture.finishStop()
  await stopping.value
  try await eventually { backend.messages.contains { $0["method"] == "cancel-voice" } }
  #expect(!backend.messages.contains { $0["method"] == "voice" })
  #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
  #expect(workspace.draft == "Keep me.")
  #expect(workspace.errorMessage == nil)
}

@MainActor @Test func aCancelDuringTheEncodeSendsNothingAndDeletesTheClip() async throws {
  let (voice, workspace, backend, _, _) = await makeVoice(draft: "Keep me.")
  let base = try clipBase()
  defer { try? FileManager.default.removeItem(at: base) }
  voice.temporaryFolder = base
  await voice.toggle()
  let stopping = Task { await voice.toggle() }
  // The stop runs up to the encode, which goes off the main actor. The test keeps the main actor
  // from here to the cancel, so the cancel always comes before the encode's result is read.
  await Task.yield()
  #expect(voice.phase == .transcribing)
  voice.cancel()
  await stopping.value
  try await eventually { backend.messages.contains { $0["method"] == "cancel-voice" } }
  #expect(!backend.messages.contains { $0["method"] == "voice" })
  #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
  #expect(workspace.draft == "Keep me.")
  #expect(workspace.errorMessage == nil)
}
