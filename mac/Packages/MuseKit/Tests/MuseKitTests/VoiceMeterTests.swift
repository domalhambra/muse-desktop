import Testing
@testable import MuseKit

@Test func silenceDrawsTheLowestBars() {
  #expect(VoiceMeter.levels([Float](repeating: 0, count: 500)) == [0.22, 0.22, 0.22, 0.22, 0.22])
}

@Test func noSamplesDrawTheLowestBars() {
  #expect(VoiceMeter.levels([]) == [0.22, 0.22, 0.22, 0.22, 0.22])
}

@Test func fullScaleFillsEveryBar() {
  #expect(VoiceMeter.levels([Float](repeating: 1, count: 500)) == [1, 1, 1, 1, 1])
}

@Test func minusTwentyDecibelsFillsSixTenths() {
  let levels = VoiceMeter.levels([Float](repeating: 0.1, count: 500))
  #expect(levels.count == 5)
  #expect(levels.allSatisfy { abs($0 - 0.6) < 0.001 })
}

@Test func eachBarIsOneFifthOfTheSamples() {
  let samples = [Float](repeating: 1, count: 100) + [Float](repeating: 0, count: 400)
  #expect(VoiceMeter.levels(samples) == [1, 0.22, 0.22, 0.22, 0.22])
}

@Test func theMeterReportsEvery120Milliseconds() {
  #expect(VoiceMeter.interval == 0.12)
}
