import Foundation
import MuseBackend
import Testing
@testable import MuseKit

private let utc = TimeZone(identifier: "UTC")!
private var calendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = utc
  return calendar
}
private let locale = Locale(identifier: "en_US")
/// Monday 2026-10-26 12:00 UTC, in epoch milliseconds.
private let noon = Date(timeIntervalSince1970: 1_793_016_000)
private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

private func limits(window: Int = 42, weekly: Int = 18, minutes: Int = 300, observed: Date = noon,
                    windowReset: Date = noon.addingTimeInterval(13_200), weeklyReset: Date = noon.addingTimeInterval(7 * 86_400 - 10_800)) -> SubscriptionLimits {
  SubscriptionLimits(
    observedAt: ms(observed), tier: "pro",
    window: .init(usedPercent: window, resetsAt: ms(windowReset), minutes: minutes),
    weekly: .init(usedPercent: weekly, resetsAt: ms(weeklyReset)))
}

@Test func levelsTurnAtEightyAndAHundred() {
  #expect(UsageRules.level(79) == .normal)
  #expect(UsageRules.level(80) == .warning)
  #expect(UsageRules.level(99) == .warning)
  #expect(UsageRules.level(100) == .full)
  #expect(UsageRules.level(112) == .full)
}

@Test func theFooterNamesTheWindowByItsLengthAndShowsOverAHundred() {
  #expect(UsageRules.footer(limits(), now: noon) == "5-hour 42% \u{00B7} Week 18%")
  #expect(UsageRules.footer(limits(minutes: 60), now: noon) == "1-hour 42% \u{00B7} Week 18%")
  #expect(UsageRules.footer(limits(minutes: 90), now: noon) == "90-minute 42% \u{00B7} Week 18%")
  #expect(UsageRules.footer(limits(window: 112), now: noon) == "5-hour 112% \u{00B7} Week 18%")
}

@Test func aLimitResetSinceTheLastUpdateShowsNoPercentAndNoLevel() {
  let stale = limits(window: 95, observed: noon, windowReset: noon.addingTimeInterval(60))
  let later = noon.addingTimeInterval(120)
  #expect(UsageRules.footer(stale, now: later) == "5-hour reset \u{00B7} Week 18%")
  #expect(UsageRules.footerLevel(stale, now: later) == .normal)
  #expect(UsageRules.footerLevel(limits(window: 85), now: noon) == .warning)
  #expect(UsageRules.footerLevel(limits(weekly: 100), now: noon) == .full)
}

@Test func resetTextIsATimeTodayAndADayOtherwise() {
  let today = noon.addingTimeInterval(13_200)  // 15:40
  let monday = noon.addingTimeInterval(7 * 86_400 - 10_800)  // next Mon 09:00
  #expect(UsageRules.resetText(ms(today), now: noon, calendar: calendar, locale: locale) == "resets 3:40\u{202F}PM")
  #expect(UsageRules.resetText(ms(monday), now: noon, calendar: calendar, locale: locale) == "resets Mon 9:00\u{202F}AM")
}

@Test func costAndTokensLines() {
  #expect(UsageRules.costText(SessionCost(usd: 0.8412, partial: false)) == "~$0.84")
  #expect(UsageRules.costText(SessionCost(usd: 0.84, partial: true)) == "~$0.84 (partial)")
  let usage = Usage(input: 100_000, output: 28_400, total: 128_400)
  #expect(UsageRules.tokensLine(usage: usage, cost: SessionCost(usd: 0.84, partial: false)) == "128,400 tokens \u{00B7} ~$0.84")
  #expect(UsageRules.tokensLine(usage: usage, cost: nil) == "128,400 tokens")
  #expect(UsageRules.tokensLine(usage: nil, cost: nil) == nil)
}

@Test func theStopBannerNamesTheLimitByItsResetTime() {
  let all = limits()
  let window = QuotaStop(kind: "tierLimit", resetsAt: all.window.resetsAt + 30_000)
  let weekly = QuotaStop(kind: "tierLimit", resetsAt: all.weekly.resetsAt)
  let other = QuotaStop(kind: "tierLimit", resetsAt: all.window.resetsAt + 3_600_000)
  #expect(UsageRules.stopBanner(window, limits: all, now: noon, calendar: calendar, locale: locale)
    == "Session limit reached. Resets at 3:40\u{202F}PM.")
  #expect(UsageRules.stopBanner(weekly, limits: all, now: noon, calendar: calendar, locale: locale)
    == "Weekly limit reached. Resets Mon 9:00\u{202F}AM.")
  #expect(UsageRules.stopBanner(other, limits: all, now: noon, calendar: calendar, locale: locale)
    == "Usage limit reached. Resets at 4:40\u{202F}PM.")
  #expect(UsageRules.stopBanner(window, limits: nil, now: noon, calendar: calendar, locale: locale)
    == "Usage limit reached. Resets at 3:40\u{202F}PM.")
}

@Test func theSpokenLabelReadsPercentAndReset() {
  #expect(UsageRules.spoken(name: "Session limit", percent: 42, reset: "resets 3:40 PM")
    == "Session limit 42 percent used, resets 3:40 PM")
}

@Test func theSpokenFooterHasNoSeparatorAndSaysReset() {
  let limits = SubscriptionLimits(
    observedAt: 1_000, tier: "pro", window: .init(usedPercent: 80, resetsAt: 2_000_000, minutes: 300),
    weekly: .init(usedPercent: 20, resetsAt: 3_000_000))
  #expect(UsageRules.spokenFooter(limits, now: Date(timeIntervalSince1970: 1))
    == "5-hour 80 percent, week 20 percent")
  #expect(UsageRules.spokenFooter(limits, now: Date(timeIntervalSince1970: 2_500))
    == "5-hour reset, week 20 percent")
}
