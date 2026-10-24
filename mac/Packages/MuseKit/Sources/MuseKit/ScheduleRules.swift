import Foundation
import MuseBackend

/// The Scheduled pane's words and checks. The backend owns cron evaluation and gives `nextRunAt`,
/// which is daylight-saving correct; these rules only format it and never compute a run time.
public enum ScheduleRules {
  public static let presets = ["hourly", "daily", "weekdays", "weekly", "manual", "custom"]

  /// The form's first problem, or nil. The cron checks match src/headless/schedule-rules.ts
  /// `checkCron`: five fields, then a minute of one or two ASCII digits from 0 to 59. The backend
  /// still parses the whole expression when it saves.
  public static func validate(_ input: ScheduleInput) -> String? {
    if input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the task a name." }
    if input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write the instructions Muse runs." }
    if input.folder.isEmpty { return "Choose a folder." }
    guard input.preset == "custom" else { return nil }
    let fields = (input.cron ?? "").split(whereSeparator: \.isWhitespace)
    if fields.count != 5 { return "A custom schedule has five fields: minute, hour, day, month, weekday." }
    let minute = fields[0]
    if (1...2).contains(minute.count), minute.allSatisfy({ $0.isASCII && $0.isNumber }),
      let value = Int(minute), value <= 59
    {
      return nil
    }
    return "A custom schedule runs at most once an hour, so its minute must be one number from 0 to 59."
  }

  public static func trigger(_ schedule: Schedule, calendar: Calendar = .current, locale: Locale = .current) -> String {
    let time = clock(hour: schedule.hour, minute: schedule.minute, calendar: calendar, locale: locale)
    switch schedule.preset {
    case "hourly": return "Every hour at :\(String(format: "%02d", schedule.minute))"
    case "daily": return "Every day at \(time)"
    case "weekdays": return "Weekdays at \(time)"
    case "weekly":
      var symbols = calendar
      symbols.locale = english
      return "\(symbols.weekdaySymbols[((schedule.weekday % 7) + 7) % 7])s at \(time)"
    case "custom": return "Custom: \(schedule.cron ?? "")"
    default: return "Manual"
    }
  }

  public static func nextRun(
    _ entry: ScheduleEntry, now: Date, calendar: Calendar = .current, locale: Locale = .current
  ) -> String {
    if !entry.schedule.enabled { return "Paused" }
    guard let next = entry.nextRunAt else { return "Runs only with Run now" }
    return "Next run \(when(next, now: now, calendar: calendar, locale: locale))"
  }

  public static func historyLine(
    _ run: ScheduleRun, now: Date, calendar: Calendar = .current, locale: Locale = .current
  ) -> String {
    let at = when(run.at, now: now, calendar: calendar, locale: locale)
    let verb = run.outcome == "started" ? "Started" : run.outcome == "skipped" ? "Skipped" : "Failed"
    return run.reason.map { "\(verb) \(at): \($0)" } ?? "\(verb) \(at)"
  }

  public static func finishedNotice(name: String) -> String { "Scheduled task \(name) finished" }

  /// The form's fields for an existing task. The id makes Save change it rather than add one.
  public static func input(from schedule: Schedule) -> ScheduleInput {
    ScheduleInput(
      id: schedule.id, name: schedule.name, prompt: schedule.prompt, folder: schedule.folder, preset: schedule.preset,
      minute: schedule.minute, hour: schedule.hour, weekday: schedule.weekday, cron: schedule.cron,
      approvalMode: schedule.approvalMode, modelId: schedule.modelId, worktree: schedule.worktree,
      enabled: schedule.enabled)
  }

  /// The sentences are English, so day and month names are too. Times follow `locale`.
  private static let english = Locale(identifier: "en_US")

  private static func clock(hour: Int, minute: Int, calendar: Calendar, locale: Locale) -> String {
    var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
    style.timeZone = calendar.timeZone
    let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: hour, minute: minute)) ?? .now
    return date.formatted(style)
  }

  /// "today 3:40 PM"; "Mon 9:00 AM" within a week either way, where a weekday names one day;
  /// otherwise "Oct 3, 9:00 AM".
  private static func when(_ epochMs: Double, now: Date, calendar: Calendar, locale: Locale) -> String {
    let date = Date(timeIntervalSince1970: epochMs / 1000)
    var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
    time.timeZone = calendar.timeZone
    if calendar.isDate(date, inSameDayAs: now) { return "today \(date.formatted(time))" }
    var english = calendar
    english.locale = Self.english
    if abs(date.timeIntervalSince(now)) < 7 * 86_400 {
      var day = Date.FormatStyle(locale: Self.english, calendar: english).weekday(.abbreviated)
      day.timeZone = calendar.timeZone
      return "\(date.formatted(day)) \(date.formatted(time))"
    }
    var day = Date.FormatStyle(locale: Self.english, calendar: english).month(.abbreviated).day()
    day.timeZone = calendar.timeZone
    return "\(date.formatted(day)), \(date.formatted(time))"
  }
}
