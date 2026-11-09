import Foundation
import MuseBackend
import Testing
@testable import MuseKit

@Test func pairsFollowElectronsParser() throws {
  #expect(try SettingsRules.pairs(" A = 1 \n\n B=x=y ", separator: "=") == ["A": "1", "B": "x=y"])
  #expect(try SettingsRules.pairs("Authorization: Bearer t", separator: ":") == ["Authorization": "Bearer t"])
  #expect(throws: WorkspaceError("Write each line as name=value: novalue")) {
    try SettingsRules.pairs("novalue", separator: "=")
  }
  #expect(throws: WorkspaceError("Write each line as name:value: :x")) {
    try SettingsRules.pairs(":x", separator: ":")
  }
}

@Test func pastedWindowsLineEndingsSplitLines() throws {
  #expect(try SettingsRules.pairs("A=1\r\nB=2\r\n", separator: "=") == ["A": "1", "B": "2"])
  var form = McpForm()
  form.name = "files"
  form.command = "npx"
  form.arguments = "-y\r\n@scope/server"
  #expect(try form.input() == .stdio(name: "files", command: "npx", args: ["-y", "@scope/server"], env: [:]))
}

@Test func aFormBuildsEachInput() throws {
  var form = McpForm()
  form.name = " files "
  form.command = " npx "
  form.arguments = "-y\n\n @scope/server \n"
  form.environment = "TOKEN=abc"
  #expect(try form.input() == .stdio(name: "files", command: "npx", args: ["-y", "@scope/server"], env: ["TOKEN": "abc"]))
  form.kind = .remote
  form.url = " https://e.com/mcp "
  form.headers = ""
  #expect(try form.input() == .http(name: "files", url: "https://e.com/mcp", headers: [:]))
}

@Test func aFormRejectsABadPairLine() {
  var form = McpForm()
  form.name = "files"
  form.command = "npx"
  form.environment = "TOKEN"
  #expect(throws: WorkspaceError("Write each line as name=value: TOKEN")) { try form.input() }
  form.kind = .remote
  form.headers = "Authorization Bearer t"
  #expect(throws: WorkspaceError("Write each line as name:value: Authorization Bearer t")) { try form.input() }
}

@Test func portsMustBeInRange() {
  #expect(SettingsRules.port("7735") == 7735)
  #expect(SettingsRules.port(" 1024 ") == 1024)
  #expect(SettingsRules.port("65535") == 65535)
  #expect(SettingsRules.port("7735\n") == 7735)
  #expect(SettingsRules.port("1023") == nil)
  #expect(SettingsRules.port("65536") == nil)
  #expect(SettingsRules.port("77.5") == nil)
  #expect(SettingsRules.port("") == nil)
  #expect(SettingsRules.portError == "Use a port between 1024 and 65535.")
}

@Test func themesKeepOnlyMuseAndMoonlight() {
  #expect(ThemeName(preference: "moonlight") == .moonlight)
  #expect(ThemeName(preference: "system") == .moonlight)
  for other in ["muse", "daylight", "grove", "plush", "nonsense"] { #expect(ThemeName(preference: other) == .muse) }
  #expect(ThemeName.muse.label == "Muse" && ThemeName.muse.hint == "Electric blue")
  #expect(ThemeName.moonlight.label == "Moonlight" && ThemeName.moonlight.hint == "Soft and dark")
  #expect(ThemeName.moonlight.palette.base == "#141b28")
  #expect(ThemeName.muse.palette.base == "#062565")
  #expect(ThemeName.muse.palette.backgroundStops == ["#082968", "#061b52", "#072e83"])
}

@Test func palettesHoldSixDigitHexValues() {
  for theme in ThemeName.allCases {
    let palette = theme.palette
    let colors =
      [
        palette.base, palette.sidebar, palette.text, palette.heading, palette.secondary, palette.muted,
        palette.accent, palette.onPrimary, palette.dialog, palette.input, palette.selection, palette.focus,
        palette.green, palette.red, palette.warning, palette.codeBackground,
      ] + palette.backgroundStops + (palette.glow.map { [$0] } ?? [])
    for color in colors {
      #expect(color.wholeMatch(of: /#[0-9a-f]{6}/) != nil, "\(theme) has \(color)")
    }
  }
  #expect(ThemeName.moonlight.palette.glow == nil)
  #expect(ThemeName.muse.palette.glow == "#0758cd")
}

@Test func textSizesMatchTheReadingSizes() {
  #expect(TextSize(preference: "compact").points == 14)
  #expect(TextSize(preference: "comfortable").points == 15)
  #expect(TextSize(preference: "large").points == 17)
  #expect(TextSize(preference: "huge") == .comfortable)
}

@Test func aNoticePostsOnlyForABackgroundTurnThatEnded() {
  #expect(CompletionNotice.shouldPost(previous: "running", next: "idle", enabled: true, focused: false))
  #expect(!CompletionNotice.shouldPost(previous: "running", next: "idle", enabled: false, focused: false))
  #expect(!CompletionNotice.shouldPost(previous: "running", next: "idle", enabled: true, focused: true))
  #expect(!CompletionNotice.shouldPost(previous: "idle", next: "idle", enabled: true, focused: false))
  #expect(!CompletionNotice.shouldPost(previous: nil, next: "idle", enabled: true, focused: false))
  #expect(!CompletionNotice.shouldPost(previous: "running", next: "error", enabled: true, focused: false))
}

@Test func aNoticeNamesTheConversation() throws {
  func session(name: String? = nil, title: String? = nil) throws -> Session {
    try JSONDecoder().decode(Session.self, from: Data(sessionJSON("s1", name: name, title: title).utf8))
  }
  let named = CompletionNotice.content(for: try session(name: "Release notes", title: "Draft"))
  #expect(named.title == "Muse is ready for you" && named.body == "Release notes")
  #expect(CompletionNotice.content(for: try session(title: "Draft")).body == "Draft")
  #expect(CompletionNotice.content(for: try session(name: "", title: "Draft")).body == "Draft")
  #expect(CompletionNotice.content(for: try session()).body == "Your conversation has an update.")
}
