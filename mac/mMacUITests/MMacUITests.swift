import AppKit
import XCTest

/// Drives mMac with every Muse path in a temporary folder. Run with
/// TEST_RUNNER_MUSE_BIN="$(command -v muse)" so the echo test uses the installed CLI.
@MainActor
final class MMacUITests: XCTestCase {
  private var temporary: URL!
  /// mMac's remembered `inspectorShown`, kept aside so each test starts with the inspector hidden
  /// and Dom's own setting comes back afterwards.
  private var savedInspectorShown: Any?

  /// mMac's defaults. The app's HOME is temporary, but its preferences still live in the user's.
  private static let appDefaults = "com.domalhambra.mmac"
  private static let inspectorShownKey = "inspectorShown"

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
    let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.appDefaults))
    savedInspectorShown = defaults.object(forKey: Self.inspectorShownKey)
    defaults.removeObject(forKey: Self.inspectorShownKey)
  }

  // Teardown blocks, which stop the app, run before this.
  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: temporary)
    let defaults = UserDefaults(suiteName: Self.appDefaults)
    if let savedInspectorShown {
      defaults?.set(savedInspectorShown, forKey: Self.inspectorShownKey)
    } else {
      defaults?.removeObject(forKey: Self.inspectorShownKey)
    }
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

  private func quit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(
      app.wait(for: .notRunning, timeout: 15), "mMac did not quit within 15 seconds", file: file, line: line)
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
  private func openFakeConversation(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(
      app.staticTexts["Connected to Muse Code"].waitForExistence(timeout: 30), file: file, line: line)
    let row = app.staticTexts["Fake conversation"]
    XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
    row.click()
    XCTAssertTrue(
      app.staticTexts["Open the fake conversation?"].waitForExistence(timeout: 10), file: file, line: line)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.staticTexts["Approval required"].waitForExistence(timeout: 10), file: file, line: line)
  }

  /// Waits until `element` is enabled: an action disables the buttons while it runs.
  private func waitUntilEnabled(
    _ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      element.wait(for: \.isEnabled, toEqual: true, timeout: timeout),
      "\(element) did not become enabled within \(timeout) seconds", file: file, line: line)
  }

  /// Waits until `element`'s accessibility value is `value`, such as a toggle's "Shown".
  private func waitForValue(
    _ element: XCUIElement, _ value: String, timeout: TimeInterval = 5, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
    XCTAssertEqual(
      XCTWaiter().wait(for: [matches], timeout: timeout), .completed,
      "\(element) did not read \"\(value)\" within \(timeout) seconds", file: file, line: line)
  }

  /// Waits until the fake backend has logged `expected`, so the next click cannot race the action
  /// before it.
  private func waitUntilLogged(
    _ log: URL, _ expected: NSDictionary, timeout: TimeInterval = 10, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let found = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        ((try? Self.logged(log)) ?? []).contains { $0 == expected }
      }, object: nil)
    XCTAssertEqual(
      XCTWaiter().wait(for: [found], timeout: timeout), .completed,
      "\(expected) was not logged within \(timeout) seconds. The log: \((try? Self.logged(log)) ?? [])",
      file: file, line: line)
  }

  /// Checks that the log holds `expected`, and prints the log when it does not.
  private func assertLogged(
    _ entries: [NSDictionary?], _ expected: NSDictionary, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      entries.contains { $0 == expected }, "\(expected) is not in the log: \(entries)", file: file, line: line)
  }

  /// An inspector tab. A segmented control's segments are radio buttons on macOS; the label can
  /// carry a count, such as "Activity 1".
  private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
  }

  /// The logged requests and answers of the fake backend.
  private nonisolated static func logged(_ log: URL) throws -> [NSDictionary?] {
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
    // Every item goes back with every type it had, not only its plain text.
    let board = NSPasteboard.general
    let saved = (board.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    addTeardownBlock { @MainActor in
      let board = NSPasteboard.general
      board.clearContents()
      let items = saved.map { entries in
        let item = NSPasteboardItem()
        for (type, data) in entries { item.setData(data, forType: type) }
        return item
      }
      if !items.isEmpty { board.writeObjects(items) }
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

    let entries = try Self.logged(log)
    assertLogged(entries, ["answer": 1, "choice": 1])
    assertLogged(entries, ["method": "approve", "args": ["fake-1", "appr-1", "once"]])
    assertLogged(
      entries, ["method": "answer", "args": ["fake-1", "ask-1", [["questionId": "color", "selectedLabel": "Blue"]]]])
    assertLogged(entries, ["method": "set-model", "args": ["fake-1", "fake-two"]])
    XCTAssertTrue(entries.contains { $0?["method"] as? String == "shutdown" })
  }

  func testTheInspectorReviewsChangesAgainstTheFakeBackend() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let project = temporary.appending(path: "project").path
    let worktree = "\(project)/.muse/worktrees/feature"
    let app = try launchFake(log: log)
    openFakeConversation(app)

    // setUp cleared the remembered state, so the inspector starts hidden.
    let toggle = app.buttons["Toggle project inspector"]
    waitForValue(toggle, "Hidden")
    toggle.click()
    waitForValue(toggle, "Shown")

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
    waitUntilLogged(log, ["method": "git-revert-hunk", "args": [project, "src/app.swift", 0]])

    let stage = app.buttons["Stage"]
    waitUntilEnabled(stage)
    stage.click()
    waitUntilLogged(log, ["method": "git-stage-file", "args": [project, "src/app.swift"]])

    let revertFile = app.buttons["Revert file"].firstMatch
    waitUntilEnabled(revertFile)
    revertFile.click()
    XCTAssertTrue(app.staticTexts["Discard all changes to src/app.swift?"].waitForExistence(timeout: 10))
    app.sheets.buttons["Revert file"].click()
    waitUntilLogged(log, ["method": "git-revert-file", "args": [project, "src/app.swift"]])

    app.buttons["Back to the changed files"].click()
    let merge = app.buttons["Merge feature into main"]
    XCTAssertTrue(merge.waitForExistence(timeout: 10))
    waitUntilEnabled(merge)
    merge.click()
    waitUntilLogged(log, ["method": "worktree-merge", "args": [project, worktree]])
    XCTAssertTrue(app.staticTexts["Merged muse/feature."].waitForExistence(timeout: 10))
    let remove = app.buttons["Remove worktree feature"]
    waitUntilEnabled(remove)
    remove.click()
    XCTAssertTrue(app.staticTexts["Remove the worktree feature?"].waitForExistence(timeout: 10))
    app.sheets.buttons["Remove"].click()
    waitUntilLogged(log, ["method": "worktree-remove", "args": [project, worktree]])

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

    // The review and worktree calls were each waited for above.
    assertLogged(try Self.logged(log), ["method": "read-file", "args": [project, "src/app.swift"]])
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
    let entries = try Self.logged(log)
    assertLogged(entries, ["answer": 2, "choice": 0])
    assertLogged(entries, ["method": "rename", "args": ["fake-1", "Renamed by test"]])
  }
}
