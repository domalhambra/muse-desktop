import Foundation
import MuseBackend
import Testing
@testable import MuseKit

// 2026-10-21 12:00 UTC.
private let base = Date(timeIntervalSince1970: 1_792_584_000)

private func iso(minutesAgo: Int) -> String {
  ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(-minutesAgo * 60)))
}

private func session(
  _ id: String, root: String? = "/Users/dom/app", minutesAgo: Int, activityMinutesAgo: Int? = nil,
  name: String? = nil, kind: String? = nil
) -> Session {
  Session(
    sessionId: id, workspaceRoot: root, updatedAt: iso(minutesAgo: minutesAgo),
    lastActivityAt: activityMinutesAgo.map { iso(minutesAgo: $0) }, name: name ?? id, kind: kind)
}

@Test func anEmptyQueryListsActionsConversationsThenThemes() {
  let entries = CommandMenu.entries(sessions: [session("chat", minutesAgo: 5)], archived: [], query: "")
  #expect(entries.map(\.title) == [
    "New conversation", "Open project", "Open settings", "chat", "Switch to Muse", "Switch to Moonlight",
  ])
  #expect(entries.map(\.subtitle) == [
    "Start a conversation", "Choose a folder on your Mac", "Appearance and Muse Code connection", "app",
    "Electric blue", "Soft and dark",
  ])
  #expect(entries.map(\.shortcut) == ["⌘ N", "⌘ O", "⌘ ,", nil, nil, nil])
  #expect(entries.map(\.group) == [.actions, .actions, .actions, .conversations, .themes, .themes])
  #expect(entries.map(\.action) == [
    .newConversation, .openProject, .openSettings, .open("chat"), .theme("muse"), .theme("moonlight"),
  ])
  #expect(CommandMenuGroup.allCases.map(\.rawValue) == ["Actions", "Recent conversations", "Themes"])
}

@Test func subagentReminderAndArchivedSessionsStayOut() {
  let sessions = [
    session("kept", minutesAgo: 1),
    session("sub", minutesAgo: 2, kind: "subagent"),
    session("rem", minutesAgo: 3, kind: "reminder"),
    session("archived", minutesAgo: 4),
  ]
  let entries = CommandMenu.entries(sessions: sessions, archived: ["archived"], query: "")
  #expect(entries.filter { $0.group == .conversations }.map(\.title) == ["kept"])
}

@Test func conversationsSortByLastActivityNewestFirst() {
  let sessions = [
    session("old", minutesAgo: 300),
    // Updated long ago, but active a minute ago: lastActivityAt wins, as in the sidebar.
    session("active", minutesAgo: 600, activityMinutesAgo: 1),
    session("new", minutesAgo: 10),
  ]
  let entries = CommandMenu.entries(sessions: sessions, archived: [], query: "")
  #expect(entries.filter { $0.group == .conversations }.map(\.title) == ["active", "new", "old"])
}

@Test func conversationsStopAt25AndThemesStillShow() {
  let sessions = (1...30).map { session("chat \($0)", minutesAgo: $0) }
  let entries = CommandMenu.entries(sessions: sessions, archived: [], query: "")
  let conversations = entries.filter { $0.group == .conversations }
  #expect(conversations.count == 25)
  #expect(conversations.first?.title == "chat 1")
  #expect(conversations.last?.title == "chat 25")
  #expect(entries.filter { $0.group == .themes }.count == 2)
  #expect(entries.filter { $0.group == .actions }.count == 3)
}

@Test func theFilterRunsBeforeTheCapSoOlderConversationsCanBeFound() {
  let sessions = (1...30).map { session("chat \($0)", minutesAgo: $0) }
  let entries = CommandMenu.entries(sessions: sessions, archived: [], query: "chat 30")
  #expect(entries.map(\.title) == ["chat 30"])
}

@Test func theFilterSpansTitleAndSubtitleIgnoresCaseAndKeepsSpaces() {
  // One space joins title and subtitle, so a query can span them.
  #expect(CommandMenu.entries(sessions: [], archived: [], query: "conversation start").map(\.title) == [
    "New conversation"
  ])
  #expect(CommandMenu.entries(sessions: [], archived: [], query: "DARK").map(\.title) == ["Switch to Moonlight"])
  #expect(CommandMenu.entries(sessions: [], archived: [], query: "blue").map(\.title) == ["Switch to Muse"])
  // The query is not trimmed: "dark " needs a space after "dark", and Moonlight's subtitle ends there.
  #expect(CommandMenu.entries(sessions: [], archived: [], query: "dark ").isEmpty)
  // Typing a project name finds its conversations.
  let sessions = [session("one", root: "/code/website", minutesAgo: 1), session("two", minutesAgo: 2)]
  #expect(CommandMenu.entries(sessions: sessions, archived: [], query: "website").map(\.title) == ["one"])
}

@Test func aConversationShowsItsProjectOrConversation() {
  let sessions = [
    session("rooted", root: "/Users/dom/Code/app/", minutesAgo: 1),
    session("none", root: nil, minutesAgo: 2),
    session("empty", root: "", minutesAgo: 3),
  ]
  let entries = CommandMenu.entries(sessions: sessions, archived: [], query: "").filter { $0.group == .conversations }
  #expect(entries.map(\.subtitle) == ["app", "Conversation", "Conversation"])
  // The title is the sidebar's.
  let untitled = Session(sessionId: "u", updatedAt: iso(minutesAgo: 1), firstUserPrompt: "  Fix   it ")
  #expect(CommandMenu.entries(sessions: [untitled], archived: [], query: "")[3].title == "Fix it")
}

@Test func nothingMatchingGivesAnEmptyList() {
  #expect(CommandMenu.entries(sessions: [session("chat", minutesAgo: 1)], archived: [], query: "zzz").isEmpty)
  #expect(CommandMenu.emptyState == "No matches. Try a project or conversation name.")
  #expect(CommandMenu.placeholder == "Search commands and conversations…")
  #expect(CommandMenu.fieldLabel == "Search commands and conversations")
}

@Test func theArrowsClampAtBothEnds() {
  #expect(CommandMenu.moved(0, by: -1, count: 4) == 0)
  #expect(CommandMenu.moved(0, by: 1, count: 4) == 1)
  #expect(CommandMenu.moved(3, by: 1, count: 4) == 3)
  #expect(CommandMenu.moved(2, by: -1, count: 4) == 1)
  #expect(CommandMenu.moved(5, by: 1, count: 0) == 0)
}
