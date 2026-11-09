import Foundation
import MuseBackend

/// The words of the usage footer, its popover, the context card's tokens line and the stop banner.
public enum UsageRules {
  public enum Level: Int, Comparable, Equatable, Sendable {
    case normal, warning, full
    public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// Amber from 80, red from 100.
  public static func level(_ percent: Int) -> Level {
    percent >= 100 ? .full : percent >= 80 ? .warning : .normal
  }

  /// "5-hour" for 300 minutes, "90-minute" when the length is not whole hours.
  public static func windowLabel(minutes: Int) -> String {
    minutes % 60 == 0 ? "\(minutes / 60)-hour" : "\(minutes)-minute"
  }

  /// True when the limit has reset since Muse observed it: its number no longer holds.
  public static func isStale(resetsAt: Double, observedAt: Double, now: Date) -> Bool {
    observedAt < resetsAt && now.timeIntervalSince1970 * 1000 >= resetsAt
  }

  public static func footer(_ limits: SubscriptionLimits, now: Date) -> String {
    let parts = footerParts(limits, now: now)
    let first = "\(parts.window) \(parts.windowPercent.map { "\($0)%" } ?? "reset")"
    let second = parts.weekPercent.map { "Week \($0)%" } ?? "Week reset"
    return "\(first) \u{00B7} \(second)"
  }

  /// The footer as VoiceOver reads it: "5-hour 80 percent, week 20 percent", with no "·".
  public static func spokenFooter(_ limits: SubscriptionLimits, now: Date) -> String {
    let parts = footerParts(limits, now: now)
    let first = "\(parts.window) \(parts.windowPercent.map { "\($0) percent" } ?? "reset")"
    let second = parts.weekPercent.map { "week \($0) percent" } ?? "week reset"
    return "\(first), \(second)"
  }

  /// The window's label and each limit's percent, nil where the limit has reset since Muse saw it.
  private static func footerParts(
    _ limits: SubscriptionLimits, now: Date
  ) -> (window: String, windowPercent: Int?, weekPercent: Int?) {
    let windowStale = isStale(resetsAt: limits.window.resetsAt, observedAt: limits.observedAt, now: now)
    let weekStale = isStale(resetsAt: limits.weekly.resetsAt, observedAt: limits.observedAt, now: now)
    return (
      windowLabel(minutes: limits.window.minutes), windowStale ? nil : limits.window.usedPercent,
      weekStale ? nil : limits.weekly.usedPercent
    )
  }

  /// The higher level of the limits whose numbers still hold.
  public static func footerLevel(_ limits: SubscriptionLimits, now: Date) -> Level {
    var levels: [Level] = [.normal]
    if !isStale(resetsAt: limits.window.resetsAt, observedAt: limits.observedAt, now: now) {
      levels.append(level(limits.window.usedPercent))
    }
    if !isStale(resetsAt: limits.weekly.resetsAt, observedAt: limits.observedAt, now: now) {
      levels.append(level(limits.weekly.usedPercent))
    }
    return levels.max() ?? .normal
  }

  /// "resets 3:40 PM" today, "resets Mon 9:00 AM" on another day.
  public static func resetText(
    _ resetsAt: Double, now: Date, calendar: Calendar = .current, locale: Locale = .current
  ) -> String {
    "resets \(when(resetsAt, now: now, calendar: calendar, locale: locale))"
  }

  public static func costText(_ cost: SessionCost) -> String {
    let amount = "~$" + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), cost.usd)
    return cost.partial ? "\(amount) (partial)" : amount
  }

  /// The context card's line: "128,400 tokens · ~$0.84". Nil before the first reply reports usage.
  public static func tokensLine(usage: Usage?, cost: SessionCost?) -> String? {
    guard let usage else { return nil }
    let tokens = "\(usage.total.formatted(.number.locale(Locale(identifier: "en_US")))) tokens"
    return cost.map { "\(tokens) \u{00B7} \(costText($0))" } ?? tokens
  }

  /// The banner that replaces a quota stop's raw error. `limitKind` cannot tell the two limits apart
  /// (msp.d.ts:1056), so the reset time does, within a minute.
  public static func stopBanner(
    _ quota: QuotaStop, limits: SubscriptionLimits?, now: Date, calendar: Calendar = .current,
    locale: Locale = .current
  ) -> String {
    let name: String
    if let limits, abs(limits.window.resetsAt - quota.resetsAt) <= 60_000 {
      name = "Session limit"
    } else if let limits, abs(limits.weekly.resetsAt - quota.resetsAt) <= 60_000 {
      name = "Weekly limit"
    } else {
      name = "Usage limit"
    }
    let at = when(quota.resetsAt, now: now, calendar: calendar, locale: locale)
    let sameDay = calendar.isDate(Date(timeIntervalSince1970: quota.resetsAt / 1000), inSameDayAs: now)
    return "\(name) reached. Resets \(sameDay ? "at " : "")\(at)."
  }

  /// VoiceOver's label for one limit; color never carries the meaning alone.
  public static func spoken(name: String, percent: Int, reset: String) -> String {
    "\(name) \(percent) percent used, \(reset)"
  }

  private static func when(_ epochMs: Double, now: Date, calendar: Calendar, locale: Locale) -> String {
    let date = Date(timeIntervalSince1970: epochMs / 1000)
    var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
    time.timeZone = calendar.timeZone
    if calendar.isDate(date, inSameDayAs: now) { return date.formatted(time) }
    var day = Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated)
    day.timeZone = calendar.timeZone
    return "\(date.formatted(day)) \(date.formatted(time))"
  }
}
