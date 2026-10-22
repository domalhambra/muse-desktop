import Foundation
import MuseBackend

/// The Settings window's rules. Electron keeps them in `McpSettings.tsx`, `BridgeSettings.tsx`,
/// `Settings.tsx` and `tokens.css`.
public enum SettingsRules {
  public static let portError = "Use a port between 1024 and 65535."

  /// One `KEY=value` (env) or `Name: value` (headers) pair per line, as Electron's `parsePairs`.
  public static func pairs(_ text: String, separator: Character) throws -> [String: String] {
    var pairs: [String: String] = [:]
    // `isNewline` splits "\r\n" too: Swift reads it as one Character, so `separator: "\n"` would not.
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      guard let index = trimmed.firstIndex(of: separator), index > trimmed.startIndex else {
        throw WorkspaceError("Write each line as name\(separator)value: \(trimmed)")
      }
      let key = trimmed[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = trimmed[trimmed.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
      pairs[key] = value
    }
    return pairs
  }

  /// The bridge port typed in the field, or nil when it is not a whole number from 1024 to 65535.
  public static func port(_ text: String) -> Int? {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (1024...65535).contains(value) else {
      return nil
    }
    return value
  }
}

/// The Add server form.
public struct McpForm: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case local, remote
    public var label: String { self == .local ? "Local command" : "Remote URL" }
  }

  public var kind: Kind = .local
  public var name = ""
  public var command = ""
  /// One argument per line.
  public var arguments = ""
  /// One KEY=value per line.
  public var environment = ""
  public var url = ""
  /// One Name: value per line.
  public var headers = ""

  public init() {}

  /// The server to send. The backend checks the name and the URL and returns Electron's errors.
  public func input() throws -> McpServerInput {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch kind {
    case .local:
      let args = arguments.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      return .stdio(
        name: name, command: command.trimmingCharacters(in: .whitespacesAndNewlines), args: args,
        env: try SettingsRules.pairs(environment, separator: "="))
    case .remote:
      return .http(
        name: name, url: url.trimmingCharacters(in: .whitespacesAndNewlines),
        headers: try SettingsRules.pairs(headers, separator: ":"))
    }
  }
}

/// The two kept themes. Both are dark.
public enum ThemeName: String, CaseIterable, Sendable, Identifiable {
  case muse, moonlight

  /// `system` shows Moonlight, as Electron does on a dark Mac. Any other value shows Muse.
  public init(preference: String) {
    self = preference == "moonlight" || preference == "system" ? .moonlight : .muse
  }

  public var id: String { rawValue }
  public var label: String { self == .muse ? "Muse" : "Moonlight" }
  public var hint: String { self == .muse ? "Electric blue" : "Soft and dark" }

  /// The colors from `src/renderer/src/tokens.css`.
  public var palette: ThemePalette {
    switch self {
    case .muse:
      ThemePalette(
        base: "#062565", backgroundStops: ["#082968", "#061b52", "#072e83"], glow: "#0758cd",
        sidebar: "#0a347c", text: "#f0f5ff", heading: "#f5f8ff", secondary: "#c0d5fb", muted: "#b4caee",
        accent: "#b5d4ff", onPrimary: "#0753dd", dialog: "#0c2c66", input: "#061d4e", selection: "#397dde",
        focus: "#b2d9ff", green: "#85e1b5", red: "#ffb3b9", warning: "#ead095", codeBackground: "#071e50")
    case .moonlight:
      ThemePalette(
        base: "#141b28", backgroundStops: ["#141b28"], glow: nil,
        sidebar: "#17202d", text: "#e1e5ee", heading: "#e9e9ef", secondary: "#a8b1c3", muted: "#a0aec6",
        accent: "#b4bee4", onPrimary: "#182239", dialog: "#1c2536", input: "#152133", selection: "#52678b",
        focus: "#a1b7e5", green: "#8cbc9e", red: "#d49399", warning: "#d3b16d", codeBackground: "#101a2b")
    }
  }
}

/// A theme's colors as `#rrggbb`. Alpha values from tokens.css are left to the views.
public struct ThemePalette: Equatable, Sendable {
  public let base: String
  /// The color stops of tokens.css's `--app-background` linear gradient. Muse's is
  /// `linear-gradient(125deg, #082968, #061b52 63%, #072e83)`: 125 degrees, the middle stop at 63%.
  /// Moonlight has one stop, a solid color. Task 10 (`Theme.swift`) draws the angle and the glow.
  public let backgroundStops: [String]
  /// Muse's radial glow over the gradient: `radial-gradient(ellipse at 95% 0%, #0758cd 0%, transparent 62%)`.
  public let glow: String?
  public let sidebar, text, heading, secondary, muted, accent, onPrimary, dialog, input: String
  public let selection, focus, green, red, warning, codeBackground: String
}

/// Electron's text sizes: only the reading size of the transcript changes.
public enum TextSize: String, CaseIterable, Sendable, Identifiable {
  case compact, comfortable, large

  public init(preference: String) { self = TextSize(rawValue: preference) ?? .comfortable }

  public var id: String { rawValue }
  public var label: String { rawValue.capitalized }
  /// `--reading-size` in tokens.css.
  public var points: Double {
    switch self {
    case .compact: 14
    case .comfortable: 15
    case .large: 17
    }
  }
}

/// The notification Electron posts when a turn ends while the window is not focused.
public enum CompletionNotice {
  public static func shouldPost(previous: String?, next: String, enabled: Bool, focused: Bool) -> Bool {
    previous == "running" && next == "idle" && enabled && !focused
  }

  public static func content(for session: Session) -> (title: String, body: String) {
    let body = [session.name, session.title].compactMap { $0 }.first { !$0.isEmpty }
    return ("Muse is ready for you", body ?? "Your conversation has an update.")
  }
}
