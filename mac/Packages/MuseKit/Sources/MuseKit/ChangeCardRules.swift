import Foundation
import MuseBackend

/// The PR monitor's rules: the checks summary, when to poll, and the Auto-fix prompt.
public enum PullRequestRules {
  public struct Summary: Equatable, Sendable {
    public let passing: Int
    public let failing: Int
    public let pending: Int
    public let text: String
  }

  public static func summary(_ checks: [PullRequestCheck]) -> Summary {
    let passing = checks.filter { $0.state == "passing" }.count
    let failing = checks.filter { $0.state == "failing" }.count
    let pending = checks.filter { $0.state == "pending" }.count
    let parts = [(passing, "passing"), (failing, "failing"), (pending, "pending")]
      .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
    return Summary(passing: passing, failing: failing, pending: pending, text: parts.isEmpty ? "No checks" : parts.joined(separator: ", "))
  }

  /// The first look always reads; after that, every 60 seconds while a PR exists and Changes shows.
  public static func shouldPoll(showingChanges: Bool, hasPullRequest: Bool, lastPoll: Date?, now: Date) -> Bool {
    guard showingChanges else { return false }
    guard let lastPoll else { return true }
    return hasPullRequest && now.timeIntervalSince(lastPoll) >= 60
  }

  public static func autoFixPrompt(_ pr: PullRequest) -> String {
    let failing = pr.checks.filter { $0.state == "failing" }.map(\.name)
    return """
      The CI checks of pull request \(pr.number) fail: \(failing.joined(separator: ", ")). \
      Read their logs with `gh run view --log-failed` (find the runs with `gh pr checks \(pr.number)`), \
      find the cause, fix it on this branch, and run the checks that fail locally before you push.
      """
  }
}

/// A pull request as a change card on a delivery track, for someone who does not follow Git.
public enum ChangeCardRules {
  public enum Step: Int, CaseIterable, Sendable {
    case drafted, checked, ready, accepted, live
    public var title: String {
      switch self {
      case .drafted: "Drafted"
      case .checked: "Checked"
      case .ready: "Ready for you"
      case .accepted: "Accepted"
      case .live: "Live"
      }
    }
  }
  public struct Track: Equatable, Sendable {
    public let step: Step
    /// A check fails: the Checked step shows red.
    public let failing: Bool
  }
  public enum Light: Sendable { case green, amber, red }
  public struct Risk: Equatable, Sendable {
    public let light: Light
    public let reason: String
    public init(light: Light, reason: String) {
      self.light = light
      self.reason = reason
    }
  }

  public static func track(_ pr: PullRequest) -> Track {
    if pr.state == "MERGED" { return Track(step: pr.live ? .live : .accepted, failing: false) }
    if pr.isDraft { return Track(step: .drafted, failing: false) }
    let failing = pr.checks.contains { $0.state == "failing" }
    let pending = pr.checks.contains { $0.state == "pending" }
    if failing || pending || !["CLEAN", "HAS_HOOKS"].contains(pr.mergeState) {
      return Track(step: .checked, failing: failing)
    }
    return Track(step: .ready, failing: false)
  }

  private static let redGroups: [(test: @Sendable (String) -> Bool, reason: String)] = [
    ({ $0.hasPrefix("src/main/") || $0 == "src/headless/wire.ts" }, "changes how mMac talks to Muse"),
    ({ ["package.json", "package-lock.json", "Package.swift", "Package.resolved"].contains(($0 as NSString).lastPathComponent) }, "changes the dependencies"),
    ({ $0.hasPrefix(".github/workflows/") }, "changes the automated checks"),
    ({ $0.hasSuffix(".entitlements") || ($0 as NSString).lastPathComponent == "Info.plist" }, "changes the app\u{2019}s permissions"),
  ]

  private static func isDoc(_ path: String) -> Bool { path.hasSuffix(".md") || path.hasPrefix("docs/") }
  private static func isTest(_ path: String) -> Bool {
    path.hasPrefix("tests/") || path.contains("Tests/") || path.contains("Fixtures/")
  }

  /// From the changed paths only, never the code: red if any path is in a red group, green when
  /// every path is docs or tests, amber otherwise.
  public static func risk(_ paths: [String]) -> Risk {
    if paths.isEmpty { return Risk(light: .green, reason: "changes no files") }
    for group in redGroups where paths.contains(where: group.test) {
      return Risk(light: .red, reason: group.reason)
    }
    if paths.allSatisfy(isDoc) { return Risk(light: .green, reason: "touches only docs") }
    if paths.allSatisfy({ isDoc($0) || isTest($0) }) { return Risk(light: .green, reason: "touches only docs and tests") }
    return Risk(light: .amber, reason: "changes the app\u{2019}s code")
  }

  /// The open PR whose head branch is this PR's base: accept it first.
  public static func dependency(of pr: PullRequest, in prs: [PullRequest]) -> PullRequest? {
    prs.first { $0.state == "OPEN" && $0.number != pr.number && $0.headRefName == pr.baseRefName }
  }

  public static func blocker(of pr: PullRequest, in prs: [PullRequest]) -> String? {
    dependency(of: pr, in: prs).map { "Accept PR \($0.number) first" }
  }

  /// Newest first, with each PR after the one it depends on.
  public static func ordered(_ prs: [PullRequest]) -> [PullRequest] {
    var remaining = prs.sorted { $0.number > $1.number }
    var result: [PullRequest] = []
    while !remaining.isEmpty {
      let index = remaining.firstIndex { pr in
        guard let parent = dependency(of: pr, in: prs) else { return true }
        return result.contains { $0.number == parent.number }
      } ?? 0
      result.append(remaining.remove(at: index))
    }
    return result
  }

  /// One sentence for Dom: from "What changes for you" or "Summary", otherwise the title. Fenced
  /// (``` or ~~~) and indented code blocks are skipped; Markdown marks are removed.
  public static func headline(title: String, body: String) -> String {
    var inCode = false
    var inSection = false
    for raw in body.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") || line.hasPrefix("~~~") { inCode.toggle(); continue }
      if inCode { continue }
      // An indented code block: four spaces or a tab.
      if raw.hasPrefix("    ") || raw.hasPrefix("\t") { continue }
      if line.hasPrefix("#") {
        let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
        inSection = heading == "what changes for you" || heading == "summary"
        continue
      }
      if inSection, !line.isEmpty { return firstSentence(plain(line)) }
    }
    return plain(title)
  }

  /// Images under "Before" and "After", otherwise up to the first two in the body.
  public static func pictures(_ body: String) -> [URL] {
    let pattern = #"!\[[^\]]*\]\(([^)\s]+)\)|<img[^>]*src="([^"]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    func images(_ text: String) -> [URL] {
      regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
        let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        return Range(range, in: text).flatMap { URL(string: String(text[$0])) }
      }
    }
    let sections = body.components(separatedBy: "\n#")
    let before = sections.first { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased().hasPrefix("before") }
    let after = sections.first { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased().hasPrefix("after") }
    let paired = [before, after].compactMap { $0.flatMap { images($0).first } }
    return paired.isEmpty ? Array(images(body).prefix(2)) : paired
  }

  public static func owner(of pr: PullRequest, worktrees: [WorktreeEntry]) -> String? {
    worktrees.first { ($0.branch ?? "").replacingOccurrences(of: "refs/heads/", with: "") == pr.headRefName }?
      .sessionIds.first
  }

  public static func askWhyPrompt(_ pr: PullRequest) -> String {
    """
    Explain pull request \(pr.number), "\(pr.title)", for someone who does not use Git. Say what changes \
    for them when it is accepted, why it was made, and what could go wrong. Use plain words and no code. \
    Read it with `gh pr view \(pr.number)` and `gh pr diff \(pr.number)`.
    """
  }

  public static func acceptedText(_ pr: PullRequest) -> String { "Accepted into \(pr.baseRefName)" }

  private static func plain(_ text: String) -> String {
    var result = text
    if result.hasPrefix("- ") || result.hasPrefix("* ") { result.removeFirst(2) }
    result = result.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    for mark in ["**", "__", "`"] { result = result.replacingOccurrences(of: mark, with: "") }
    return result.trimmingCharacters(in: .whitespaces)
  }

  private static func firstSentence(_ text: String) -> String {
    if let end = text.range(of: ". ") { return String(text[..<end.lowerBound]) + "." }
    return text
  }
}
