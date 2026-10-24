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
  #expect(ChangeCardRules.blocker(of: child, in: [child, merged]) == "Its draft copy was accepted; move it onto main first")
  #expect(ChangeCardRules.blocker(of: other, in: [child, other, merged]) == nil)
}

@Test func aPullRequestOnAMergedBranchIsBlockedUntilMoved() {
  // PR 12 sits on PR 9's branch; PR 9 was accepted into extensions, so 12 would land in a dead branch.
  let merged = PullRequest(number: 9, title: "Usage", state: "MERGED", baseRefName: "extensions", headRefName: "usage")
  let child = PullRequest(number: 12, title: "Limits", baseRefName: "usage", headRefName: "limits")
  #expect(ChangeCardRules.blocker(of: child, in: [merged, child]) == "Its draft copy was accepted; move it onto extensions first")
  // An open parent still asks for it first.
  let open = PullRequest(number: 9, title: "Usage", baseRefName: "extensions", headRefName: "usage")
  #expect(ChangeCardRules.blocker(of: child, in: [open, child]) == "Accept PR 9 first")
  // The merged PR itself has no blocker.
  #expect(ChangeCardRules.blocker(of: merged, in: [merged, child]) == nil)
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
  // Only an accepted card says where it landed.
  #expect(ChangeCardRules.acceptedText(pr, track: ChangeCardRules.track(pr)) == nil)
  let merged = PullRequest(number: 9, title: "Usage", state: "MERGED", baseRefName: "extensions")
  #expect(ChangeCardRules.acceptedText(merged, track: ChangeCardRules.track(merged)) == "Accepted into extensions")
}

@Test func theHeadlineSkipsTildeFencesAndIndentedCode() {
  let body = "~~~\n## Summary\nlet secret = 1\n~~~\n## Summary\n    let code = 1\nThe footer shows usage. More.\n"
  #expect(ChangeCardRules.headline(title: "Title", body: body) == "The footer shows usage.")
}

@Test func theHeadlineSkipsRawHtmlImagesAndTables() {
  let body = "## Summary\n<img src=\"https://x/a.png\">\n![shot](https://x/b.png)\n| a | b |\nThe footer shows usage. More.\n"
  #expect(ChangeCardRules.headline(title: "Title", body: body) == "The footer shows usage.")
  #expect(ChangeCardRules.headline(title: "Title", body: "## Summary\n<!-- note -->\n") == "Title")
}

@Test func picturesKeepOnlyHttps() {
  let body = "![a](file:///etc/passwd) ![b](http://x/b.png) ![c](data:image/png;base64,AA) ![d](https://x/d.png)"
  #expect(ChangeCardRules.pictures(body).map(\.absoluteString) == ["https://x/d.png"])
  #expect(ChangeCardRules.pictures("# Before\n![a](http://x/a.png)\n# After\n![b](https://x/b.png)").map(\.absoluteString) == ["https://x/b.png"])
}

@Test func theConversationCardSeesTheProjectsCardsSoAMergedParentBlocksIt() {
  let merged = PullRequest(number: 9, title: "Usage", state: "MERGED", baseRefName: "extensions", headRefName: "usage")
  let stale = PullRequest(number: 12, title: "Old title", baseRefName: "usage", headRefName: "limits")
  let fresh = PullRequest(number: 12, title: "Limits", baseRefName: "usage", headRefName: "limits")
  let all = ChangeCardRules.siblings(of: fresh, cards: [stale, merged])
  // One entry per number, and the conversation's own read wins over the list's older copy.
  #expect(all.map(\.number).sorted() == [9, 12])
  #expect(all.first { $0.number == 12 }?.title == "Limits")
  #expect(ChangeCardRules.blocker(of: fresh, in: all) == "Its draft copy was accepted; move it onto extensions first")
  // With no cards read, the card has only itself and no blocker.
  #expect(ChangeCardRules.siblings(of: fresh, cards: []).map(\.number) == [12])
}

@Test func theHeadlineSkipsAMultiLineHtmlComment() {
  let body = "## Summary\n<!--\nThe template says: describe it here.\n-->\nThe footer shows usage. More.\n"
  #expect(ChangeCardRules.headline(title: "Title", body: body) == "The footer shows usage.")
  let unclosed = "## Summary\n<!-- left open\nHidden line.\n"
  #expect(ChangeCardRules.headline(title: "Title", body: unclosed) == "Title")
  let inline = "## Summary\n<!-- one line --> \nShown line.\n"
  #expect(ChangeCardRules.headline(title: "Title", body: inline) == "Shown line.")
}

@Test func aPullRequestMergedIntoAnAcceptedDraftCopyDoesNotReadAsAccepted() {
  // PR 9 was accepted into extensions; PR 12 was then merged on GitHub into PR 9's branch, usage.
  let parent = PullRequest(number: 9, title: "Usage", state: "MERGED", baseRefName: "extensions", headRefName: "usage")
  let child = PullRequest(number: 12, title: "Limits", state: "MERGED", baseRefName: "usage", headRefName: "limits")
  let all = [parent, child]
  #expect(ChangeCardRules.strandedParent(of: child, in: all)?.number == 9)
  let track = ChangeCardRules.track(child, in: all)
  #expect(track.step == .checked && !track.failing)
  #expect(track.movesOnto == "extensions")
  #expect(
    ChangeCardRules.acceptedText(child, track: track)
      == "Merged into usage, a draft copy that was already accepted. Move the change onto extensions.")
  // The parent itself, and a merged PR whose base no merged PR heads, read as accepted.
  #expect(ChangeCardRules.strandedParent(of: parent, in: all) == nil)
  let parentTrack = ChangeCardRules.track(parent, in: all)
  #expect(parentTrack.step == .accepted && parentTrack.movesOnto == nil)
  #expect(ChangeCardRules.acceptedText(parent, track: parentTrack) == "Accepted into extensions")
  // An open parent on that branch is not an accepted draft copy.
  let open = PullRequest(number: 9, title: "Usage", baseRefName: "extensions", headRefName: "usage")
  #expect(ChangeCardRules.strandedParent(of: child, in: [open, child]) == nil)
  #expect(ChangeCardRules.track(child, in: [open, child]).step == .accepted)
}

@Test func aChainOfAcceptedDraftCopiesPointsAtTheFirstRealBase() {
  // A went into main, B into A's branch, C into B's branch: C's change belongs on main.
  let a = PullRequest(number: 1, title: "A", state: "MERGED", baseRefName: "main", headRefName: "a")
  let b = PullRequest(number: 2, title: "B", state: "MERGED", baseRefName: "a", headRefName: "b")
  let c = PullRequest(number: 3, title: "C", state: "MERGED", baseRefName: "b", headRefName: "c")
  #expect(ChangeCardRules.strandedParent(of: c, in: [a, b, c])?.number == 2)
  #expect(ChangeCardRules.track(c, in: [a, b, c]).movesOnto == "main")
  // An open PR on C's branch is told the same base.
  let d = PullRequest(number: 4, title: "D", baseRefName: "b", headRefName: "d")
  #expect(ChangeCardRules.blocker(of: d, in: [a, b, d]) == "Its draft copy was accepted; move it onto main first")
  // Two merged PRs into each other's branches: the walk stops instead of looping.
  let x = PullRequest(number: 5, title: "X", state: "MERGED", baseRefName: "y", headRefName: "x")
  let y = PullRequest(number: 6, title: "Y", state: "MERGED", baseRefName: "x", headRefName: "y")
  let z = PullRequest(number: 7, title: "Z", state: "MERGED", baseRefName: "x", headRefName: "z")
  #expect(ChangeCardRules.strandedParent(of: z, in: [x, y, z])?.number == 5)
  #expect(ChangeCardRules.track(z, in: [x, y, z]).movesOnto != nil)
}
