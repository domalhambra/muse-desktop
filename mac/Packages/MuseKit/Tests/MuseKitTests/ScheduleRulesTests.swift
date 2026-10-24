import Foundation
import MuseBackend
import Testing
@testable import MuseKit

private var utc: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}
private let locale = Locale(identifier: "en_US")
/// Monday 2026-10-26 12:00 UTC.
private let noon = Date(timeIntervalSince1970: 1_793_016_000)
private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

private func input(_ preset: String = "daily", cron: String? = nil) -> ScheduleInput {
  ScheduleInput(name: "Morning review", prompt: "Review.", folder: "/p", preset: preset, minute: 0, hour: 9,
                weekday: 1, cron: cron, approvalMode: "onRequest")
}
private func schedule(_ preset: String = "daily", minute: Int = 0, cron: String? = nil, enabled: Bool = true) -> Schedule {
  Schedule(id: "a", name: "Morning review", prompt: "Review.", folder: "/p", preset: preset, minute: minute,
           hour: 9, weekday: 1, cron: cron, approvalMode: "onRequest", modelId: nil, worktree: false,
           enabled: enabled, createdAt: 0)
}

@Test func scheduleRulesValidateAndDescribeTheNextRun() {
  #expect(ScheduleRules.validate(input()) == nil)
  var empty = input()
  empty.name = "  "
  #expect(ScheduleRules.validate(empty) == "Give the task a name.")
  empty = input(); empty.prompt = ""
  #expect(ScheduleRules.validate(empty) == "Write the instructions Muse runs.")
  empty = input(); empty.folder = ""
  #expect(ScheduleRules.validate(empty) == "Choose a folder.")
  #expect(ScheduleRules.validate(input("custom", cron: "0 9 * *"))?.contains("five fields") == true)
  #expect(ScheduleRules.validate(input("custom", cron: "*/5 * * * *"))?.contains("at most once an hour") == true)
  // As the backend's checkCron: one or two digits, so a padded or out-of-range minute fails.
  #expect(ScheduleRules.validate(input("custom", cron: "059 9 * * 1"))?.contains("at most once an hour") == true)
  #expect(ScheduleRules.validate(input("custom", cron: "60 9 * * 1"))?.contains("at most once an hour") == true)
  #expect(ScheduleRules.validate(input("custom", cron: "15 9 * * 1")) == nil)

  let today = ScheduleEntry(schedule: schedule(), nextRunAt: ms(noon.addingTimeInterval(13_200)), history: [])
  let monday = ScheduleEntry(schedule: schedule(), nextRunAt: ms(noon.addingTimeInterval(7 * 86_400 - 10_800)), history: [])
  #expect(ScheduleRules.nextRun(today, now: noon, calendar: utc, locale: locale) == "Next run today 3:40\u{202F}PM")
  #expect(ScheduleRules.nextRun(monday, now: noon, calendar: utc, locale: locale) == "Next run Mon 9:00\u{202F}AM")
  #expect(ScheduleRules.nextRun(ScheduleEntry(schedule: schedule(enabled: false), nextRunAt: nil, history: []), now: noon) == "Paused")
  #expect(ScheduleRules.nextRun(ScheduleEntry(schedule: schedule("manual"), nextRunAt: nil, history: []), now: noon) == "Runs only with Run now")
}

@Test func triggersReadAsWords() {
  #expect(ScheduleRules.trigger(schedule("hourly", minute: 15), locale: locale) == "Every hour at :15")
  #expect(ScheduleRules.trigger(schedule(), locale: locale) == "Every day at 9:00\u{202F}AM")
  #expect(ScheduleRules.trigger(schedule("weekdays"), locale: locale) == "Weekdays at 9:00\u{202F}AM")
  #expect(ScheduleRules.trigger(schedule("weekly"), locale: locale) == "Mondays at 9:00\u{202F}AM")
  #expect(ScheduleRules.trigger(schedule("manual"), locale: locale) == "Manual")
  #expect(ScheduleRules.trigger(schedule("custom", cron: "15 9 * * 1"), locale: locale) == "Custom: 15 9 * * 1")
}

@Test func historyLinesAndTheNotice() {
  let nine = ms(noon.addingTimeInterval(-10_800))
  // Tuesday 2026-10-20 9:00, less than a week back, so the weekday names it.
  let lastTuesday = ms(noon.addingTimeInterval(-6 * 86_400 - 10_800))
  #expect(ScheduleRules.historyLine(ScheduleRun(at: nine, outcome: "started", sessionId: "s"), now: noon, calendar: utc, locale: locale)
    == "Started today 9:00\u{202F}AM")
  #expect(ScheduleRules.historyLine(
    ScheduleRun(at: lastTuesday, outcome: "skipped", reason: "Another scheduled task was running."),
    now: noon, calendar: utc, locale: locale)
    == "Skipped Tue 9:00\u{202F}AM: Another scheduled task was running.")
  #expect(ScheduleRules.historyLine(ScheduleRun(at: nine, outcome: "failed", reason: "No folder."), now: noon, calendar: utc, locale: locale)
    == "Failed today 9:00\u{202F}AM: No folder.")
  #expect(ScheduleRules.finishedNotice(name: "Morning review") == "Scheduled task Morning review finished")
}

@Test func aTimeAWeekOrMoreAwayShowsItsDate() {
  // Monday 2026-10-19 9:00, a week and three hours back: "Mon" would read as today's weekday.
  let weekAgo = ms(noon.addingTimeInterval(-7 * 86_400 - 10_800))
  #expect(ScheduleRules.historyLine(ScheduleRun(at: weekAgo, outcome: "started", sessionId: "s"), now: noon, calendar: utc, locale: locale)
    == "Started Oct 19, 9:00\u{202F}AM")
  let later = ScheduleEntry(schedule: schedule(), nextRunAt: ms(noon.addingTimeInterval(8 * 86_400 - 10_800)), history: [])
  #expect(ScheduleRules.nextRun(later, now: noon, calendar: utc, locale: locale) == "Next run Nov 3, 9:00\u{202F}AM")
}

@Test func theSentencesKeepEnglishDayNamesInAnotherLocale() {
  // German times have no AM or PM; the day and month names stay English.
  let german = Locale(identifier: "de_DE")
  var calendar = utc
  calendar.locale = german
  #expect(ScheduleRules.trigger(schedule("weekly"), calendar: calendar, locale: german) == "Mondays at 9:00")
  let monday = ScheduleEntry(schedule: schedule(), nextRunAt: ms(noon.addingTimeInterval(7 * 86_400 - 10_800)), history: [])
  #expect(ScheduleRules.nextRun(monday, now: noon, calendar: calendar, locale: german) == "Next run Mon 9:00")
  let later = ScheduleEntry(schedule: schedule(), nextRunAt: ms(noon.addingTimeInterval(8 * 86_400 - 10_800)), history: [])
  #expect(ScheduleRules.nextRun(later, now: noon, calendar: calendar, locale: german) == "Next run Nov 3, 9:00")
}
