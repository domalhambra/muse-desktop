import Foundation
import MuseBackend
import Testing
@testable import MuseKit

private func check(_ state: String, _ name: String = "check") -> PullRequestCheck { PullRequestCheck(name: name, state: state) }

@Test func checksSummarizeToPassingFailingPending() {
  let summary = PullRequestRules.summary([check("passing"), check("passing"), check("failing"), check("skipped")])
  #expect(summary.passing == 2 && summary.failing == 1 && summary.pending == 0)
  #expect(summary.text == "2 passing, 1 failing")
  #expect(PullRequestRules.summary([]).text == "No checks")
}

@Test func pollingRunsOnFirstLookThenEveryMinuteWithAPullRequest() {
  let now = Date(timeIntervalSince1970: 1000)
  #expect(PullRequestRules.shouldPoll(showingChanges: true, hasPullRequest: false, lastPoll: nil, now: now))
  #expect(!PullRequestRules.shouldPoll(showingChanges: false, hasPullRequest: true, lastPoll: nil, now: now))
  #expect(!PullRequestRules.shouldPoll(showingChanges: true, hasPullRequest: true, lastPoll: now.addingTimeInterval(-59), now: now))
  #expect(PullRequestRules.shouldPoll(showingChanges: true, hasPullRequest: true, lastPoll: now.addingTimeInterval(-60), now: now))
  #expect(!PullRequestRules.shouldPoll(showingChanges: true, hasPullRequest: false, lastPoll: now.addingTimeInterval(-600), now: now))
}

@Test func theAutoFixPromptNamesTheFailingChecks() {
  let pr = PullRequest(number: 9, title: "Usage", checks: [check("failing", "e2e"), check("passing", "lint"), check("failing", "check")])
  let prompt = PullRequestRules.autoFixPrompt(pr)
  #expect(prompt.contains("pull request 9"))
  #expect(prompt.contains("e2e") && prompt.contains("check") && !prompt.contains("lint"))
  #expect(prompt.contains("gh run view --log-failed"))
}

@Test func theTrackStepFollowsDraftChecksAndMerge() {
  #expect(ChangeCardRules.track(PullRequest(number: 1, title: "", isDraft: true)).step == .drafted)
  #expect(ChangeCardRules.track(PullRequest(number: 1, title: "", checks: [check("pending")])).step == .checked)
  let failing = ChangeCardRules.track(PullRequest(number: 1, title: "", checks: [check("failing")]))
  #expect(failing.step == .checked && failing.failing)
  #expect(ChangeCardRules.track(PullRequest(number: 1, title: "", mergeState: "CLEAN", checks: [check("passing")])).step == .ready)
  #expect(ChangeCardRules.track(PullRequest(number: 1, title: "", mergeState: "HAS_HOOKS")).step == .ready)
  #expect(ChangeCardRules.track(PullRequest(number: 1, title: "", mergeState: "BLOCKED")).step == .checked)
  #expect(ChangeCardRules.track(PullRequest(number: 1, title: "", state: "MERGED")).step == .accepted)
  #expect(ChangeCardRules.track(PullRequest(number: 1, title: "", state: "MERGED", live: true)).step == .live)
  #expect(ChangeCardRules.Step.allCases.map(\.title) == ["Drafted", "Checked", "Ready for you", "Accepted", "Live"])
}

@Test func theRiskLightTakesTheHighestRankedPathAndItsReason() {
  #expect(ChangeCardRules.risk(["docs/a.md", "README.md"]) == .init(light: .green, reason: "touches only docs"))
  #expect(ChangeCardRules.risk(["docs/a.md", "tests/unit/a.test.ts"]) == .init(light: .green, reason: "touches only docs and tests"))
  #expect(ChangeCardRules.risk(["mac/mMac/SidebarView.swift", "docs/a.md"]) == .init(light: .amber, reason: "changes the app\u{2019}s code"))
  #expect(ChangeCardRules.risk(["mac/mMac/A.swift", "src/main/muse-host.ts"]) == .init(light: .red, reason: "changes how mMac talks to Muse"))
  #expect(ChangeCardRules.risk(["package-lock.json"]) == .init(light: .red, reason: "changes the dependencies"))
  #expect(ChangeCardRules.risk([".github/workflows/check.yml"]) == .init(light: .red, reason: "changes the automated checks"))
  #expect(ChangeCardRules.risk(["mac/mMac/mMac.entitlements"]) == .init(light: .red, reason: "changes the app\u{2019}s permissions"))
  #expect(ChangeCardRules.risk([]) == .init(light: .green, reason: "changes no files"))
}

@Test func dependenciesOrderCardsByBaseBranch() {
  let base = PullRequest(number: 9, title: "Usage", baseRefName: "main", headRefName: "usage")
  let child = PullRequest(number: 12, title: "Limits", baseRefName: "usage", headRefName: "limits")
  let other = PullRequest(number: 11, title: "Docs", baseRefName: "main", headRefName: "docs")
  let ordered = ChangeCardRules.ordered([child, other, base])
  #expect(ordered.map(\.number).firstIndex(of: 9)! < ordered.map(\.number).firstIndex(of: 12)!)
  #expect(ChangeCardRules.blocker(of: child, in: [child, other, base]) == "Accept PR 9 first")
  #expect(ChangeCardRules.blocker(of: base, in: [child, other, base]) == nil)
  let merged = PullRequest(number: 9, title: "Usage", state: "MERGED", baseRefName: "main", headRefName: "usage")
  #expect(ChangeCardRules.blocker(of: child, in: [child, merged]) == nil)
}

@Test func theHeadlineComesFromTheTitleAndBodyNeverCode() {
  let body = "```swift\nlet secret = 1\n```\n## What changes for you\n**mMac** now shows your usage limits in the footer. More text.\n"
  #expect(ChangeCardRules.headline(title: "mac: usage footer", body: body) == "mMac now shows your usage limits in the footer.")
  #expect(ChangeCardRules.headline(title: "Fix the [export](https://x) toast", body: "") == "Fix the export toast")
  #expect(ChangeCardRules.headline(title: "Title", body: "## Summary\n- `Usage` shows.\n") == "Usage shows.")
}

@Test func picturesComeFromBeforeAndAfterOrTheFirstTwoImages() {
  let body = "## Before\n![old](https://x/old.png)\n## After\n<img src=\"https://x/new.png\">\n![extra](https://x/3.png)"
  #expect(ChangeCardRules.pictures(body).map(\.absoluteString) == ["https://x/old.png", "https://x/new.png"])
  #expect(ChangeCardRules.pictures("![a](https://x/a.png) ![b](https://x/b.png) ![c](https://x/c.png)").count == 2)
  #expect(ChangeCardRules.pictures("No images.").isEmpty)
}

@Test func theOwnerIsTheWorktreeOnTheHeadBranch() {
  let worktrees = [
    WorktreeEntry(path: "/p", branch: "refs/heads/main", isMain: true, sessionIds: []),
    WorktreeEntry(path: "/p/.muse/worktrees/a", branch: "refs/heads/usage", isMain: false, sessionIds: ["s1"]),
  ]
  #expect(ChangeCardRules.owner(of: PullRequest(number: 9, title: "", headRefName: "usage"), worktrees: worktrees) == "s1")
  #expect(ChangeCardRules.owner(of: PullRequest(number: 9, title: "", headRefName: "other"), worktrees: worktrees) == nil)
}

@Test func askWhyAndAcceptedText() {
  let pr = PullRequest(number: 9, title: "Usage", baseRefName: "extensions")
  #expect(ChangeCardRules.askWhyPrompt(pr).contains("does not use Git"))
  #expect(ChangeCardRules.askWhyPrompt(pr).contains("pull request 9"))
  #expect(ChangeCardRules.acceptedText(pr) == "Accepted into extensions")
}

@Test func theHeadlineSkipsTildeFencesAndIndentedCode() {
  let body = "~~~\n## Summary\nlet secret = 1\n~~~\n## Summary\n    let code = 1\nThe footer shows usage. More.\n"
  #expect(ChangeCardRules.headline(title: "Title", body: body) == "The footer shows usage.")
}
