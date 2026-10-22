import AppKit
import XCTest

/// Drives mMac with every Muse path in a temporary folder. Run with
/// TEST_RUNNER_MUSE_BIN="$(command -v muse)" so the echo test uses the installed CLI.
@MainActor
final class MMacUITests: XCTestCase {
  private var temporary: URL!

  /// The repository root: this file is `mac/mMacUITests/MMacUITests.swift`.
  private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  override func setUp() async throws {
    continueAfterFailure = false
    temporary = FileManager.default.temporaryDirectory.appending(path: "mmac-ui-\(UUID().uuidString)")
    for folder in ["app-data", "project", "muse", "config", "data", "state"] {
      try FileManager.default.createDirectory(
        at: temporary.appending(path: folder), withIntermediateDirectories: true)
    }
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: temporary)
  }

  private func launch(cliPath: String, extra: [String: String] = [:]) throws -> XCUIApplication {
    try JSONSerialization.data(withJSONObject: ["cliPath": cliPath])
      .write(to: temporary.appending(path: "app-data/preferences.json"))
    let app = XCUIApplication()
    app.launchEnvironment = [
      "HOME": temporary.path,
      // A login shell started under HOME must not read the real dotfiles.
      "ZDOTDIR": temporary.path,
      "MUSE_HOME": temporary.appending(path: "muse").path,
      "XDG_CONFIG_HOME": temporary.appending(path: "config").path,
      "XDG_DATA_HOME": temporary.appending(path: "data").path,
      "XDG_STATE_HOME": temporary.appending(path: "state").path,
      "MUSE_DESKTOP_TEST_PROVIDER": "echo",
      "MUSE_NO_AUTO_UPDATE": "1",
      "MMAC_DATA_FOLDER": temporary.appending(path: "app-data").path,
      "MMAC_TEST_PROJECT": temporary.appending(path: "project").path,
    ].merging(extra) { $1 }
    // Run the backend from this checkout, whatever the build recorded.
    app.launchArguments = ["-MMacRepository", repository.path]
    app.launch()
    // A test that fails partway still stops the app, and with it the backend, before tearDown
    // deletes the temporary folder.
    addTeardownBlock { @MainActor in
      if app.state != .notRunning { app.terminate() }
    }
    return app
  }

  private func quit(_ app: XCUIApplication) {
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "mMac did not quit within 15 seconds")
  }

  /// Launches mMac on the fake backend, which logs to `log`.
  private func launchFake(log: URL) throws -> XCUIApplication {
    try launch(
      cliPath: "",
      extra: [
        "MMAC_BACKEND_SCRIPT": repository.appending(path: "mac/Fixtures/fake-backend.mjs").path,
        "FAKE_BACKEND_LOG": log.path,
      ])
  }

  /// Opens the fake conversation and presses Escape on the Ask it raises first. Escape must choose
  /// the last button.
  private func openFakeConversation(_ app: XCUIApplication) {
    XCTAssertTrue(app.staticTexts["Connected to Muse Code"].waitForExistence(timeout: 30))
    let row = app.staticTexts["Fake conversation"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    XCTAssertTrue(app.staticTexts["Open the fake conversation?"].waitForExistence(timeout: 10))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.staticTexts["Approval required"].waitForExistence(timeout: 10))
  }

  /// Waits until `element` is enabled: an action disables the buttons while it runs.
  private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) {
    let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)
    wait(for: [enabled], timeout: timeout)
  }

  /// An inspector tab. A segmented control's segments are radio buttons on macOS; the label can
  /// carry a count, such as "Activity 1".
  private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
  }

  /// The logged requests and answers of the fake backend.
  private func logged(_ log: URL) throws -> [NSDictionary?] {
    try String(contentsOf: log, encoding: .utf8)
      .split(separator: "\n")
      .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }
  }

  func testAnEchoConversationEndToEnd() throws {
    let muse = try XCTUnwrap(
      ProcessInfo.processInfo.environment["MUSE_BIN"],
      #"Run with TEST_RUNNER_MUSE_BIN="$(command -v muse)"."#)
    let app = try launch(cliPath: muse)
    XCTAssertTrue(app.staticTexts["Connected to Muse Code"].waitForExistence(timeout: 30))

    let composer = app.descendants(matching: .any)["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    // Typing backticks once took 20 seconds and timed the test out. A paste is instant. The
    // pasteboard is Dom's, so its text goes back afterwards.
    let board = NSPasteboard.general
    let saved = board.string(forType: .string)
    addTeardownBlock { @MainActor in
      board.clearContents()
      if let saved { board.setString(saved, forType: .string) }
    }
    let message = "Check this\n```swift\nlet x = 1\n```"
    board.clearContents()
    board.setString(message, forType: .string)
    composer.click()
    composer.typeKey("v", modifierFlags: .command)
    XCTAssertEqual(composer.value as? String, message)
    composer.typeKey(.return, modifierFlags: [])

    // The project is new to mMac, so the backend Asks to trust it.
    let trust = app.buttons["Trust project"]
    XCTAssertTrue(trust.waitForExistence(timeout: 15))
    trust.click()

    XCTAssertTrue(app.staticTexts["let x = 1"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["swift"].exists)
    // The code block's own Copy button: message headers have one labelled "Copy" as well.
    let copy = app.buttons["code-copy"]
    XCTAssertTrue(copy.exists)
    XCTAssertEqual(copy.label, "Copy")
    XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 10))

    app.descendants(matching: .any)["Conversation actions"].click()
    app.menuItems["Rename conversation…"].click()
    let name = app.textFields["Conversation name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.click()
    name.typeKey("a", modifierFlags: .command)
    name.typeText("Echo check")
    app.buttons["Save"].click()
    // The CLI lowercases ASCII letters in names, so "Echo check" comes back as "echo check".
    XCTAssertTrue(app.staticTexts["echo check"].waitForExistence(timeout: 15))

    quit(app)
  }

  func testCardsAgainstTheFakeBackend() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    openFakeConversation(app)

    XCTAssertTrue(app.staticTexts["Muse would like permission to use shell."].exists)
    XCTAssertTrue(app.staticTexts["Saves a rule"].exists)
    app.buttons["Allow once"].click()
    XCTAssertTrue(app.buttons["Allow once"].waitForNonExistence(timeout: 10))

    XCTAssertTrue(app.staticTexts["Input required"].exists)
    XCTAssertFalse(app.buttons["Continue"].isEnabled)
    app.radioButtons["Blue"].click()
    XCTAssertTrue(app.buttons["Continue"].isEnabled)
    app.buttons["Continue"].click()
    XCTAssertTrue(app.staticTexts["Input required"].waitForNonExistence(timeout: 10))

    let picker = app.descendants(matching: .any)["model-picker"]
    XCTAssertTrue(picker.exists)
    picker.click()
    app.menuItems["Fake Model Two"].click()

    quit(app)

    let entries = try logged(log)
    func has(_ expected: NSDictionary) -> Bool { entries.contains { $0 == expected } }
    XCTAssertTrue(has(["answer": 1, "choice": 1]))
    XCTAssertTrue(has(["method": "approve", "args": ["fake-1", "appr-1", "once"]]))
    XCTAssertTrue(
      has(["method": "answer", "args": ["fake-1", "ask-1", [["questionId": "color", "selectedLabel": "Blue"]]]]))
    XCTAssertTrue(has(["method": "set-model", "args": ["fake-1", "fake-two"]]))
    XCTAssertTrue(entries.contains { $0?["method"] as? String == "shutdown" })
  }

  func testTheInspectorReviewsChangesAgainstTheFakeBackend() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let project = temporary.appending(path: "project").path
    let app = try launchFake(log: log)
    openFakeConversation(app)

    // The inspector's shown state is remembered between launches, so it may already be open.
    let toggle = app.buttons["Toggle project inspector"]
    if toggle.value as? String == "Shown" {
      toggle.click()
      XCTAssertEqual(toggle.value as? String, "Hidden")
    }
    toggle.click()
    XCTAssertEqual(toggle.value as? String, "Shown")

    // A changed file's row reads its name, folder and status in words.
    let file = app.buttons["app.swift, src, Modified"]
    XCTAssertTrue(file.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["notes.md, Project root, Untracked"].exists)
    file.click()

    XCTAssertTrue(app.descendants(matching: .any)["Added, line 2, let b = 3"].waitForExistence(timeout: 10))
    let revertHunk = app.buttons["Revert hunk 1"]
    XCTAssertTrue(revertHunk.exists)
    XCTAssertEqual(revertHunk.title, "Revert hunk")
    revertHunk.click()

    let stage = app.buttons["Stage"]
    waitUntilEnabled(stage)
    stage.click()

    let revertFile = app.buttons["Revert file"].firstMatch
    waitUntilEnabled(revertFile)
    revertFile.click()
    XCTAssertTrue(app.staticTexts["Discard all changes to src/app.swift?"].waitForExistence(timeout: 10))
    app.sheets.buttons["Revert file"].click()

    let back = app.buttons["Back to the changed files"]
    waitUntilEnabled(back)
    back.click()
    let merge = app.buttons["Merge feature into main"]
    XCTAssertTrue(merge.waitForExistence(timeout: 10))
    waitUntilEnabled(merge)
    merge.click()
    XCTAssertTrue(app.staticTexts["Merged muse/feature."].waitForExistence(timeout: 10))
    let remove = app.buttons["Remove worktree feature"]
    waitUntilEnabled(remove)
    remove.click()
    XCTAssertTrue(app.staticTexts["Remove the worktree feature?"].waitForExistence(timeout: 10))
    app.sheets.buttons["Remove"].click()

    tab(app, "Files").click()
    let folder = app.buttons["src"]
    XCTAssertTrue(folder.waitForExistence(timeout: 10))
    folder.click()
    let swiftFile = app.buttons["app.swift"].firstMatch
    XCTAssertTrue(swiftFile.waitForExistence(timeout: 10))
    swiftFile.click()
    let preview = app.textViews["file-preview"]
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    XCTAssertTrue((preview.value as? String)?.contains("let b = 3") == true)
    XCTAssertTrue(app.staticTexts["4 lines"].exists)
    app.buttons["Ask Muse"].firstMatch.click()
    let composer = app.descendants(matching: .any)["composer"]
    XCTAssertTrue(
      (composer.value as? String)?.contains(#"Please look at the project file: "src/app.swift""#) == true)

    tab(app, "Activity").click()
    // An Activity row is one combined element, such as "Completed, Format on save, Ran prettier",
    // so the hook's title and detail are looked for together on it.
    let hook = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Format on save", "Ran prettier"))
      .firstMatch
    XCTAssertTrue(hook.waitForExistence(timeout: 10))

    quit(app)

    let entries = try logged(log)
    func has(_ expected: NSDictionary) -> Bool { entries.contains { $0 == expected } }
    XCTAssertTrue(has(["method": "git-revert-hunk", "args": [project, "src/app.swift", 0]]))
    XCTAssertTrue(has(["method": "git-stage-file", "args": [project, "src/app.swift"]]))
    XCTAssertTrue(has(["method": "git-revert-file", "args": [project, "src/app.swift"]]))
    XCTAssertTrue(has(["method": "worktree-merge", "args": [project, "\(project)/.muse/worktrees/feature"]]))
    XCTAssertTrue(has(["method": "worktree-remove", "args": [project, "\(project)/.muse/worktrees/feature"]]))
    XCTAssertTrue(has(["method": "read-file", "args": [project, "src/app.swift"]]))
  }

  func testAnAskShowsOverTheRenameSheet() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    openFakeConversation(app)

    app.descendants(matching: .any)["Conversation actions"].click()
    app.menuItems["Rename conversation…"].click()
    let name = app.textFields["Conversation name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.click()
    name.typeKey("a", modifierFlags: .command)
    name.typeText("Renamed by test")
    app.buttons["Save"].click()

    // The backend Asks while the rename sheet is still open. M1 could not show this.
    XCTAssertTrue(app.staticTexts["Rename needs an answer"].waitForExistence(timeout: 10))
    app.buttons["Go on"].click()
    XCTAssertTrue(name.waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Renamed by test"].waitForExistence(timeout: 10))

    quit(app)
    let entries = try logged(log)
    XCTAssertTrue(entries.contains { $0 == ["answer": 2, "choice": 0] })
    XCTAssertTrue(entries.contains { $0 == ["method": "rename", "args": ["fake-1", "Renamed by test"]] })
  }
}
