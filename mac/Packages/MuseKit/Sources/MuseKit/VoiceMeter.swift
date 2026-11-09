import Foundation

/// The voice pill's five bar heights, as `VoiceCapture.start(levels:failed:)` delivers them.
/// Electron reads FFT bins 1 to 5 every 120 ms and holds each bar between 0.22 and 1; mMac takes
/// the RMS of five equal slices of the last 120 ms instead, maps -50 dB to 0 dB onto 0 to 1, and
/// holds the bars the same way. Pure, so the recorder can call it on the audio thread.
public enum VoiceMeter {
  /// How often the bars change, in seconds, as Electron's.
  public static let interval = 0.12
  /// The lowest a bar draws, as Electron's and `VoiceSession.levels`.
  public static let floor = 0.22

  /// Five bar heights from `samples`, mono, in [-1, 1].
  public static func levels(_ samples: [Float]) -> [Double] {
    let slice = max(samples.count / 5, 1)
    return (0..<5).map { bar in
      let start = min(bar * slice, samples.count)
      let end = bar == 4 ? samples.count : min(start + slice, samples.count)
      guard end > start else { return floor }
      var sum = 0.0
      for index in start..<end { sum += Double(samples[index]) * Double(samples[index]) }
      let rms = (sum / Double(end - start)).squareRoot()
      let decibels = 20 * log10(max(rms, 1e-7))
      return min(max((decibels + 50) / 50, floor), 1)
    }
  }
}
