import Foundation
import MuseBackend
import Testing
@testable import MuseKit

private let calendar: Calendar = {
  var value = Calendar(identifier: .gregorian)
  value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  return value
}()
// 2026-10-21 12:00 Pacific.
private let now = Date(timeIntervalSince1970: 1_792_609_200)

private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

private func session(_ id: String, root: String? = "/p", hoursAgo: Double, kind: String? = nil) -> Session {
  Session(sessionId: id, workspaceRoot: root, updatedAt: iso(now.addingTimeInterval(-hoursAgo * 3600)), kind: kind)
}

@Test func titlesAreCleanedAndCut() {
  #expect(SessionTitle.text(name: nil, title: nil, firstUserPrompt: "<context a=\"1\">secret</context>  Fix   the bug") == "Fix the bug")
  #expect(SessionTitle.text(name: "  ", title: "Named", firstUserPrompt: nil) == "Named")
  #expect(SessionTitle.text(name: nil, title: nil, firstUserPrompt: nil) == "Untitled conversation")
  let long = String(repeating: "word ", count: 30)
  let cut = SessionTitle.text(name: long, title: nil, firstUserPrompt: nil)
  #expect(cut.hasSuffix("…"))
  #expect(cut.count <= 77)
}

@Test func worktreeFoldersBelongToTheirProject() {
  #expect(ProjectPath.root(of: "/p/.muse/worktrees/feature") == "/p")
  #expect(ProjectPath.root(of: "/p") == "/p")
  #expect(ProjectPath.name(of: "/Users/dom/Code/app") == "app")
  // Electron's projectName: the last non-empty part on either separator, else the path.
  #expect(ProjectPath.name(of: "/Users/dom/Code/app/") == "app")
  #expect(ProjectPath.name(of: #"C:\Code\win"#) == "win")
  #expect(ProjectPath.name(of: "/") == "/")
  #expect(ProjectPath.name(of: "") == "")
  #expect(ProjectPath.isWorktree(Session(sessionId: "s", workspaceRoot: "/p/.muse/worktrees/w", updatedAt: "x")))
}

@Test func sectionsGroupByDateAndHideSubagents() {
  let sessions = [
    session("old", hoursAgo: 24 * 30),
    session("today", hoursAgo: 1),
    session("sub", hoursAgo: 0.5, kind: "subagent"),
    session("yesterday", hoursAgo: 20),
    session("week", hoursAgo: 24 * 4),
    session("reminder", hoursAgo: 0.2, kind: "reminder"),
  ]
  let sections = SidebarSections.build(sessions, project: "", now: now, calendar: calendar)
  #expect(sections.map(\.title) == ["Today", "Yesterday", "Previous 7 days", "Earlier"])
  #expect(sections.flatMap { $0.sessions.map(\.sessionId) } == ["today", "yesterday", "week", "old"])
}

@Test func aProjectFilterKeepsItsWorktreeSessions() {
  let sessions = [
    session("main", root: "/p", hoursAgo: 1),
    session("tree", root: "/p/.muse/worktrees/w", hoursAgo: 2),
    session("other", root: "/q", hoursAgo: 3),
  ]
  let ids = SidebarSections.build(sessions, project: "/p", now: now, calendar: calendar).flatMap { $0.sessions.map(\.sessionId) }
  #expect(ids == ["main", "tree"])
}

@Test func relativeTimes() {
  #expect(RelativeTime.text(iso(now.addingTimeInterval(-20)), now: now) == "Now")
  #expect(RelativeTime.text(iso(now.addingTimeInterval(-5 * 60)), now: now) == "5m")
  #expect(RelativeTime.text(iso(now.addingTimeInterval(-3 * 3600)), now: now) == "3h")
  // 01:00 UTC on Oct 2 is still Oct 1 in Los Angeles.
  #expect(
    RelativeTime.text("2026-10-02T01:00:00Z", now: now, locale: Locale(identifier: "en_US"), calendar: calendar)
      == "Oct 1")
  #expect(RelativeTime.text("not a date", now: now) == "")
}

@Test func timestampsParseWithAndWithoutFractions() {
  #expect(RelativeTime.date("2026-10-21T19:00:00Z") == now)
  #expect(RelativeTime.date("2026-10-21T19:00:00.500Z") == now.addingTimeInterval(0.5))
  #expect(RelativeTime.date("2026-10-21T12:00:00-07:00") == now)
  #expect(RelativeTime.date("2026-10-21") == nil)
}
