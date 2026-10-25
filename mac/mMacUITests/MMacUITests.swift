import AppKit
import XCTest

/// Drives mMac with every Muse path in a temporary folder. Run with
/// TEST_RUNNER_MUSE_BIN="$(command -v muse)" so the echo test uses the installed CLI.
@MainActor
final class MMacUITests: XCTestCase {
  private var temporary: URL!
  /// The fake backend's request log, while a test runs on the fake.
  private var fakeLog: URL?

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
      // The window's remembered choices go to a suite of the tests' own, which mMac empties at
      // launch, so no test inherits the inspector's state or changes Dom's.
      "MMAC_DEFAULTS_SUITE": "com.domalhambra.mmac.uitests",
      // The bridge token lives in memory, so no test reads or writes the login Keychain.
      "MMAC_TOKEN_STORE": "memory",
    ].merging(extra) { $1 }
    // Run the backend from this checkout, whatever the build recorded. NSQuitAlwaysKeepsWindows
    // in the argument domain, which writes nothing, keeps the window out of the next launch.
    // ApplePersistenceIgnoreState skips the windows AppKit saved from Dom's own runs: a test run
    // turns restoration off for the main window (`MMacApp`), so restoring that state would open
    // no window at all, and SwiftUI then opens none either.
    // "NSWindow Frame main" in the argument domain overrides any frame AppKit saved in Dom's
    // standard defaults, which it applies before `WindowStateGuard` clears the autosave name, and
    // writes nothing. It opens every test at the default 900-point width (`WindowMetrics` in MuseKit): a
    // window frame is its content's width, and 620 points of content under a 28-point title bar.
    app.launchArguments = [
      "-MMacRepository", repository.path, "-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES",
      "-NSWindow Frame main", "120 120 900 648",
    ]
    app.launch()
    XCTAssertTrue(
      app.windows["main"].waitForExistence(timeout: 15), "No main window after launch: \(app.debugDescription)")
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

  /// Launches mMac on the fake backend, which logs to `log`. `extra` adds variables, such as the
  /// fake's own `FAKE_BACKEND_OFFLINE`.
  private func launchFake(log: URL, extra: [String: String] = [:]) throws -> XCUIApplication {
    fakeLog = log
    return try launch(
      cliPath: "",
      extra: [
        "MMAC_BACKEND_SCRIPT": repository.appending(path: "mac/Fixtures/fake-backend.mjs").path,
        "FAKE_BACKEND_LOG": log.path,
        // A second copy that outlives the temporary folder, for mac/scripts/ui-tests.sh to keep.
        // The test runner is sandboxed, so the fake writes it.
        "FAKE_BACKEND_COPY": "/private/tmp/mmac-ui-requests/\(testName)-requests.jsonl",
      ].merging(extra) { $1 })
  }

  /// The running test's method name: `name` reads "-[MMacUITests testName]".
  private var testName: String {
    name.split(separator: " ").last.map { String($0.dropLast()) } ?? "test"
  }

  /// Waits until the sidebar's status, a button that opens Settings, reads "Connected to Muse Code".
  private func waitUntilConnected(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let status = app.buttons["Muse Code settings"]
    // On the fake, a failure shows how far the backend got: hello, start, sessions. The message
    // is read only on failure, after the wait.
    XCTAssertTrue(
      status.waitForExistence(timeout: 30),
      "The sidebar status did not appear. The fake's requests: \(fakeRequests())", file: file, line: line)
    waitForValue(status, "Connected to Muse Code", timeout: 30, file: file, line: line)
  }

  /// The sidebar row titled `title`: the list cell that holds the title. A click or hover goes
  /// to the cell, not to the title's text. Until the pointer has been over a row, an accessibility
  /// hit test at the text finds the cell, so XCTest calls the text not hittable and the click
  /// fails in some launches (end run, 2026-10-25).
  private func sidebarRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.outlines.cells.containing(NSPredicate(format: "value == %@ OR label == %@", title, title)).firstMatch
  }

  /// Opens the fake conversation and presses Escape on the Ask it raises first. Escape must choose
  /// the last button.
  private func openFakeConversation(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    waitUntilConnected(app, file: file, line: line)
    let row = sidebarRow(app, "Fake conversation")
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
    _ entries: [NSDictionary], _ expected: NSDictionary, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      entries.contains { $0 == expected }, "\(expected) is not in the log: \(entries)", file: file, line: line)
  }

  /// An inspector tab. A segmented control's segments are radio buttons on macOS; the label can
  /// carry a count, such as "Activity 1".
  private func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
  }

  /// Clicks an inspector tab until it reports selected, as a segment click can land while the
  /// inspector column is still settling open.
  private func selectTab(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
    let segment = tab(app, title)
    for _ in 0..<3 {
      segment.click()
      let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: segment)
      if XCTWaiter().wait(for: [selected], timeout: 2) == .completed { return }
    }
    XCTFail("\(title) never became the selected inspector tab", file: file, line: line)
  }

  /// The Settings window. SwiftUI names it by identifier; its title follows the pane shown.
  private func settingsWindow(_ app: XCUIApplication) -> XCUIElement {
    app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
  }

  /// A Settings pane's toolbar button, such as "Bridges".
  private func pane(_ settings: XCUIElement, _ title: String) -> XCUIElement {
    settings.toolbars.buttons[title]
  }

  /// The fake's logged requests for `method`.
  private nonisolated static func requests(_ log: URL, _ method: String) throws -> [NSDictionary] {
    try logged(log).filter { $0["method"] as? String == method }
  }

  /// The logged requests and answers of the fake backend. A line that does not parse is skipped:
  /// the fake may still be writing it.
  private nonisolated static func logged(_ log: URL) throws -> [NSDictionary] {
    try String(contentsOf: log, encoding: .utf8)
      .split(separator: "\n")
      .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }
  }

  /// The fake's request log as text, for failure messages.
  private func fakeRequests() -> String {
    guard let fakeLog else { return "(not the fake)" }
    return (try? String(contentsOf: fakeLog, encoding: .utf8)) ?? "(no log yet)"
  }

  /// The composer of the conversation shown.
  private func composer(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["composer"]
  }

  /// Any element with this accessibility identifier, such as a chip or a popup row.
  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Waits up to five seconds for `element` to lie across no edge of `window`, as a column that
  /// opens settles, and fails with both frames if it never does.
  private func assertInside(
    _ element: XCUIElement, _ window: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    func inside() -> Bool {
      let frame = element.frame
      let bounds = window.frame
      return element.exists && frame.width > 0 && frame.minX >= bounds.minX - 0.5 && frame.maxX <= bounds.maxX + 0.5
    }
    let deadline = Date().addingTimeInterval(5)
    while !inside(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    XCTAssertTrue(
      inside(), "\(name) at \(element.frame) is not inside the window at \(window.frame)", file: file, line: line)
  }

  /// Opens the second fake conversation, which raises no Ask and has no cards.
  private func openSecondConversation(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    waitUntilConnected(app, file: file, line: line)
    let row = sidebarRow(app, "Second fake conversation")
    XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
    row.click()
    XCTAssertTrue(
      app.staticTexts["The second conversation says hello."].waitForExistence(timeout: 10), file: file, line: line)
  }

  /// Waits for the window's error alert that reads `message`, then presses its OK button. The
  /// alert is a sheet on the window; the Touch Bar repeats its button.
  private func dismissAlert(
    _ app: XCUIApplication, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let text = app.staticTexts
      .matching(NSPredicate(format: "value == %@ OR label == %@", message, message)).firstMatch
    XCTAssertTrue(
      text.waitForExistence(timeout: 10), "No alert reads \"\(message)\": \(app.debugDescription)", file: file,
      line: line)
    app.windows["main"].sheets.buttons["OK"].click()
    XCTAssertTrue(text.waitForNonExistence(timeout: 10), file: file, line: line)
  }

  func testAnEchoConversationEndToEnd() throws {
    let muse = try XCTUnwrap(
      ProcessInfo.processInfo.environment["MUSE_BIN"],
      #"Run with TEST_RUNNER_MUSE_BIN="$(command -v muse)"."#)
    let app = try launch(cliPath: muse)
    waitUntilConnected(app)

    let composer = self.composer(app)
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
    // The Ask is a sheet on the window. The Touch Bar repeats its buttons.
    let trust = app.windows["main"].sheets.buttons["Trust project"]
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
    XCTAssertTrue(entries.contains { $0["method"] as? String == "shutdown" })
  }

  func testTheInspectorReviewsChangesAgainstTheFakeBackend() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let project = temporary.appending(path: "project").path
    let worktree = "\(project)/.muse/worktrees/feature"
    let app = try launchFake(log: log)
    openFakeConversation(app)

    // mMac emptied the tests' defaults suite at launch, so the inspector starts hidden.
    let toggle = app.buttons["Toggle project inspector"]
    waitForValue(toggle, "Hidden")
    toggle.click()
    waitForValue(toggle, "Shown")
    // Window › Zoom fills the screen, so the inspector's right-hand buttons are inside the window
    // whatever size SwiftUI opened it at.
    app.menuBars.menuBarItems["Window"].click()
    app.menuBars.menuItems["Zoom"].click()

    // A changed file's row reads its name, folder and status in words.
    let file = app.buttons["app.swift, src, Modified"]
    XCTAssertTrue(file.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["notes.md, Project root, Untracked"].exists)
    file.click()

    XCTAssertTrue(app.descendants(matching: .any)["Added, line 2, let b = 3"].waitForExistence(timeout: 10))
    let revertHunk = app.buttons["Revert hunk 1"]
    // Its visible title, "Revert hunk", is not readable here: SwiftUI exposes only the label.
    XCTAssertTrue(revertHunk.exists)
    XCTAssertEqual(revertHunk.label, "Revert hunk 1")
    // The number is in the label: no button reads plain "Revert hunk".
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Revert hunk")).count, 0)
    revertHunk.click()
    // The hunk's text goes with its index, so the backend can refuse a hunk changed outside mMac.
    let hunk = "@@ -1,3 +1,3 @@\n let a = 1\n-let b = 2\n+let b = 3\n let c = 4"
    waitUntilLogged(log, ["method": "git-revert-hunk", "args": [project, "src/app.swift", 0, hunk]])

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
    // The text view has a width to draw in: the live run showed "41 lines" over an empty body.
    XCTAssertGreaterThan(preview.frame.width, 20, "The preview is \(preview.frame)")
    XCTAssertTrue(app.staticTexts["4 lines"].exists)
    app.buttons["Ask Muse"].firstMatch.click()
    let composer = self.composer(app)
    XCTAssertTrue(
      (composer.value as? String)?.contains(#"Please look at the project file: "src/app.swift""#) == true)

    tab(app, "Activity").click()
    // An Activity row is one combined element, such as "Completed, Format on save, Ran prettier",
    // so the hook's title and detail are looked for together on it. SwiftUI gives a combined
    // row's text as its value.
    let hook = app.descendants(matching: .any)
      .matching(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "Format on save", "Ran prettier"))
      .firstMatch
    XCTAssertTrue(hook.waitForExistence(timeout: 10))

    // Off again from the View menu's shortcut, so the tests' own defaults suite ends as it began,
    // with the inspector closed.
    app.typeKey("i", modifierFlags: [.command, .option])
    waitForValue(toggle, "Hidden")

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
    // The Ask is a sheet on the rename sheet. The Touch Bar repeats its buttons, so the button is
    // looked for there.
    app.windows["main"].sheets.sheets.buttons["Go on"].click()
    XCTAssertTrue(name.waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Renamed by test"].waitForExistence(timeout: 10))

    quit(app)
    let entries = try Self.logged(log)
    assertLogged(entries, ["answer": 2, "choice": 0])
    assertLogged(entries, ["method": "rename", "args": ["fake-1", "Renamed by test"]])
  }

  func testSettingsAgainstTheFakeBackend() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    waitUntilConnected(app)

    app.typeKey(",", modifierFlags: .command)
    let settings = settingsWindow(app)
    XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)

    try checkAppearance(settings, log: log)
    checkMuseCode(settings)
    try checkMcpServers(settings, log: log)
    try checkBridges(app, settings, log: log)

    quit(app)
  }

  /// Appearance: each choice saves on its own.
  private func checkAppearance(_ settings: XCUIElement, log: URL) throws {
    pane(settings, "Appearance").click()
    let moonlight = settings.buttons["theme-moonlight"]
    XCTAssertTrue(moonlight.waitForExistence(timeout: 10), settings.debugDescription)
    moonlight.click()
    waitUntilLogged(log, ["method": "preferences", "args": [["theme": "moonlight"]]])
    settings.radioButtons["Large"].click()
    waitUntilLogged(log, ["method": "preferences", "args": [["fontSize": "large"]]])
    let saved = try Self.requests(log, "preferences").suffix(2).map { $0["args"] as? NSArray }
    XCTAssertEqual(saved, [[["theme": "moonlight"]], [["fontSize": "large"]]])
  }

  /// Muse Code: the connection's path, and the custom path field. Both sit in a `LabeledContent`,
  /// and reading the pane's elements must not loop a label.
  private func checkMuseCode(_ settings: XCUIElement) {
    pane(settings, "Muse Code").click()
    let cliPath = settings.textFields["cli-path"]
    XCTAssertTrue(cliPath.waitForExistence(timeout: 10))
    XCTAssertEqual(cliPath.label, "Custom executable path")
    XCTAssertTrue(settings.buttons["Reconnect to Muse Code"].exists)
    // The fake's `ready` status names this path.
    XCTAssertTrue(settings.staticTexts["/usr/local/bin/muse"].waitForExistence(timeout: 5), settings.debugDescription)
  }

  /// MCP servers: add a local server, then remove it, cancelling once.
  private func checkMcpServers(_ settings: XCUIElement, log: URL) throws {
    pane(settings, "MCP servers").click()
    let add = settings.buttons["mcp-add-server"]
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    add.click()
    let sheet = settings.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5))
    let name = sheet.textFields["Name"]
    name.click()
    name.typeText("files")
    let command = sheet.textFields["Command"]
    command.click()
    command.typeText("npx")
    // Each click focused its own field: the text went where it was typed.
    XCTAssertEqual(name.value as? String, "files")
    XCTAssertEqual(command.value as? String, "npx")
    let arguments = sheet.textViews["Arguments, one per line"]
    arguments.click()
    // Return in a multi-line field makes a new line; it never presses Add server.
    arguments.typeText("a\nb")
    XCTAssertEqual(arguments.value as? String, "a\nb")
    XCTAssertTrue(sheet.buttons["mcp-add-confirm"].exists)
    XCTAssertTrue(try Self.requests(log, "mcp-add").isEmpty)
    // Typed text stays as typed: no smart dashes or quotes.
    arguments.typeKey("a", modifierFlags: .command)
    arguments.typeText(#"--port "x""#)
    sheet.buttons["mcp-add-confirm"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    let added: NSDictionary = [
      "name": "files", "transport": "stdio", "command": "npx", "args": [#"--port "x""#], "env": NSDictionary(),
    ]
    waitUntilLogged(log, ["method": "mcp-add", "args": [added]])
    let row = settings.staticTexts["files"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))

    settings.buttons["Remove files"].click()
    XCTAssertTrue(settings.sheets.buttons["Cancel"].waitForExistence(timeout: 5))
    settings.sheets.buttons["Cancel"].click()
    XCTAssertTrue(settings.sheets.firstMatch.waitForNonExistence(timeout: 5))
    XCTAssertTrue(row.exists)
    XCTAssertTrue(try Self.requests(log, "mcp-remove").isEmpty)
    settings.buttons["Remove files"].click()
    XCTAssertTrue(settings.sheets.buttons["Remove"].waitForExistence(timeout: 5))
    settings.sheets.buttons["Remove"].click()
    waitUntilLogged(log, ["method": "mcp-remove", "args": ["files"]])
    XCTAssertTrue(row.waitForNonExistence(timeout: 10))
  }

  /// Bridges: a token, shown once, then the MCP bridge on, then a refused port left unsaved.
  private func checkBridges(_ app: XCUIApplication, _ settings: XCUIElement, log: URL) throws {
    pane(settings, "Bridges").click()
    let makeToken = settings.buttons["bridge-make-token"]
    XCTAssertTrue(makeToken.waitForExistence(timeout: 10))
    // As Electron: Copy token shows only once a token exists.
    XCTAssertFalse(settings.buttons["bridge-copy-token"].exists)
    makeToken.click()
    waitUntilLogged(log, ["method": "bridge-token", "args": []])
    let token = settings.staticTexts["bridge-new-token"]
    XCTAssertTrue(token.waitForExistence(timeout: 10))
    XCTAssertEqual(token.label, "New token, shown once")
    XCTAssertTrue((token.value as? String)?.hasPrefix("fake-token-") == true, "\(String(describing: token.value))")
    XCTAssertTrue(settings.buttons["bridge-copy-token"].exists)
    let mcpBridge = settings.switches["bridge-mcp-toggle"]
    XCTAssertTrue(mcpBridge.waitForExistence(timeout: 5), settings.debugDescription)
    waitUntilEnabled(mcpBridge)
    mcpBridge.click()
    waitUntilLogged(log, ["method": "preferences", "args": [["bridgeMcpEnabled": true]]])
    let running = settings.staticTexts
      .matching(NSPredicate(format: "value CONTAINS %@", "agents that speak MCP. Running")).firstMatch
    XCTAssertTrue(running.waitForExistence(timeout: 10), settings.debugDescription)

    // A refused port typed without Return, then left by switching panes, raises no alert and
    // saves nothing. The field shows the saved port again.
    let port = settings.textFields["bridge-port"]
    XCTAssertEqual(port.value as? String, "7735")
    port.click()
    port.typeKey("a", modifierFlags: .command)
    port.typeText("80")
    waitForValue(port, "80")
    pane(settings, "Appearance").click()
    XCTAssertTrue(settings.buttons["theme-moonlight"].waitForExistence(timeout: 5))
    let alert = app.staticTexts["Use a port between 1024 and 65535."]
    XCTAssertFalse(alert.waitForExistence(timeout: 3), app.debugDescription)
    XCTAssertFalse(settings.sheets.firstMatch.exists)
    let savedPorts = try Self.requests(log, "preferences")
      .compactMap { (($0["args"] as? NSArray)?.firstObject as? NSDictionary)?["bridgeMcpPort"] }
    XCTAssertTrue(savedPorts.isEmpty, "\(savedPorts)")
    pane(settings, "Bridges").click()
    XCTAssertTrue(port.waitForExistence(timeout: 5))
    waitForValue(port, "7735")
  }

  func testARestartReopensTheConversationWithItsDraft() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    openFakeConversation(app)
    let composer = self.composer(app)

    // A draft in the second conversation.
    sidebarRow(app, "Second fake conversation").click()
    XCTAssertTrue(app.staticTexts["The second conversation says hello."].waitForExistence(timeout: 10))
    composer.click()
    composer.typeText("A draft to keep")
    XCTAssertEqual(composer.value as? String, "A draft to keep")

    // The third conversation sends the message that stops the fake.
    sidebarRow(app, "Third fake conversation").click()
    XCTAssertTrue(app.staticTexts["The third conversation says hello."].waitForExistence(timeout: 10))
    waitForValue(composer, "")
    composer.click()
    composer.typeText("crash now")
    composer.typeKey(.return, modifierFlags: [])

    let ended = app.staticTexts
      .matching(NSPredicate(format: "value BEGINSWITH %@", "The backend process ended.")).firstMatch
    XCTAssertTrue(ended.waitForExistence(timeout: 15), app.debugDescription)
    app.buttons["Restart"].click()

    // The new backend reopens the third conversation, and the second keeps its draft.
    waitUntilConnected(app)
    XCTAssertTrue(app.staticTexts["The third conversation says hello."].waitForExistence(timeout: 10))
    XCTAssertEqual(try Self.requests(log, "start").count, 2)
    // Opened once before the restart and once by the new backend.
    let opens = try Self.requests(log, "open").map { $0["args"] as? NSArray }
    XCTAssertEqual(opens.filter { $0 == ["fake-3"] }.count, 2, "\(opens)")
    XCTAssertEqual(opens.last, ["fake-3"])
    sidebarRow(app, "Second fake conversation").click()
    XCTAssertTrue(app.staticTexts["The second conversation says hello."].waitForExistence(timeout: 10))
    waitForValue(composer, "A draft to keep")

    quit(app)
  }

  // MARK: The M4a features

  func testTheCommandMenuFindsAndOpensAConversation() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    waitUntilConnected(app)

    app.typeKey("k", modifierFlags: .command)
    let menu = element(app, "command-menu")
    XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
    let field = app.textFields["command-search"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertEqual(field.label, "Search commands and conversations")
    // Every group shows before a query: the actions, the conversations and the themes.
    XCTAssertTrue(element(app, "palette-new").waitForExistence(timeout: 5))
    XCTAssertTrue(element(app, "palette-conversation:fake-1").exists)
    field.click()
    field.typeText("Second")
    let second = element(app, "palette-conversation:fake-2")
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    XCTAssertTrue(element(app, "palette-conversation:fake-1").waitForNonExistence(timeout: 5))
    XCTAssertFalse(element(app, "palette-new").exists)
    // The only row is highlighted, so Return chooses it. The sheet closes first, then it opens.
    field.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(menu.waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["The second conversation says hello."].waitForExistence(timeout: 10))
    waitUntilLogged(log, ["method": "open", "args": ["fake-2"]])

    // A query with no result shows the empty state, and Escape closes the sheet.
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.click()
    field.typeText("zzz nothing")
    let empty = element(app, "command-empty")
    XCTAssertTrue(empty.waitForExistence(timeout: 5))
    // A SwiftUI Text reports its string as the value on macOS, and its label stays empty.
    XCTAssertEqual(empty.value as? String, "No matches. Try a project or conversation name.")
    field.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(menu.waitForNonExistence(timeout: 10))

    quit(app)
  }

  func testPinsAndArchives() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    waitUntilConnected(app)

    // The pin button shows while the pointer is over the row, in place of the time.
    let second = sidebarRow(app, "Second fake conversation")
    XCTAssertTrue(second.waitForExistence(timeout: 10))
    second.hover()
    let pin = app.buttons["pin-button"]
    XCTAssertTrue(pin.waitForExistence(timeout: 5), app.debugDescription)
    // On screen, not only in the tree: the live run found the id but saw no button.
    XCTAssertTrue(pin.isHittable, "The pin button is not hittable: \(pin.frame)")
    XCTAssertEqual(pin.label, "Pin Second fake conversation")
    pin.click()
    waitUntilLogged(log, ["method": "preferences", "args": [["pinnedSessionIds": ["fake-2"]]]])
    // The row moves to the Pinned group and shows the pin icon.
    XCTAssertTrue(app.staticTexts["Pinned"].waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(app.images["Pinned"].waitForExistence(timeout: 5))
    // A pinned row shows the button too, as Unpin. Off the row first, so the hover is a new one.
    sidebarRow(app, "Third fake conversation").hover()
    second.hover()
    let unpin = app.buttons["pin-button"]
    XCTAssertTrue(unpin.wait(for: \.label, toEqual: "Unpin Second fake conversation", timeout: 5), app.debugDescription)
    XCTAssertTrue(unpin.isHittable, "The unpin button is not hittable: \(unpin.frame)")
    // The pin did not open the row.
    XCTAssertTrue(try Self.requests(log, "open").isEmpty)
    // The context menu now offers Unpin.
    second.rightClick()
    XCTAssertTrue(app.menuItems["Unpin conversation"].waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.menuItems["Unpin conversation"].waitForNonExistence(timeout: 5))

    // Archive from the context menu: the row leaves the list.
    let third = sidebarRow(app, "Third fake conversation")
    third.rightClick()
    let archive = app.menuItems["Archive in Desktop"]
    XCTAssertTrue(archive.waitForExistence(timeout: 5))
    archive.click()
    waitUntilLogged(log, ["method": "preferences", "args": [["archivedSessionIds": ["fake-3"]]]])
    XCTAssertTrue(third.waitForNonExistence(timeout: 10))

    // The Archive toggle shows the archived conversations only.
    let toggle = app.buttons["archive-toggle"]
    XCTAssertTrue(toggle.exists)
    XCTAssertEqual(toggle.label, "Show archived conversations")
    toggle.click()
    XCTAssertTrue(app.staticTexts["ARCHIVED"].waitForExistence(timeout: 5))
    XCTAssertTrue(toggle.wait(for: \.label, toEqual: "Show conversations", timeout: 5))
    XCTAssertTrue(third.waitForExistence(timeout: 5))
    XCTAssertFalse(second.exists)

    // Restore from the context menu: the archived view is empty.
    third.rightClick()
    let restore = app.menuItems["Restore conversation"]
    XCTAssertTrue(restore.waitForExistence(timeout: 5))
    restore.click()
    waitUntilLogged(log, ["method": "preferences", "args": [["archivedSessionIds": [String]()]]])
    XCTAssertTrue(app.staticTexts["No archived conversations"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Archived conversations appear here."].exists)

    // Back to the conversations: the restored row is there again.
    toggle.click()
    XCTAssertTrue(app.staticTexts["CONVERSATIONS"].waitForExistence(timeout: 5))
    XCTAssertTrue(toggle.wait(for: \.label, toEqual: "Show archived conversations", timeout: 5))
    XCTAssertTrue(third.waitForExistence(timeout: 10))
    XCTAssertTrue(second.exists)

    quit(app)
  }

  func testExportWritesAPrivateFileAndShowsTheToast() throws {
    let log = temporary.appending(path: "requests.jsonl")
    // Debug builds take this path in place of the save panel.
    let exported = temporary.appending(path: "exported.md")
    let app = try launchFake(log: log, extra: ["MMAC_TEST_EXPORT": exported.path])
    openSecondConversation(app)

    app.descendants(matching: .any)["Conversation actions"].click()
    let export = app.menuItems["Export as Markdown…"]
    XCTAssertTrue(export.waitForExistence(timeout: 5))
    export.click()

    XCTAssertTrue(app.staticTexts["Conversation exported to Markdown."].waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "toast").exists)
    // The conversation has no first prompt, so mMac sends no fallback title.
    waitUntilLogged(log, ["method": "export", "args": ["fake-2", exported.path]])
    let attributes = try FileManager.default.attributesOfItem(atPath: exported.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let text = try String(contentsOf: exported, encoding: .utf8)
    XCTAssertTrue(text.hasPrefix("# Second fake conversation\n"), text)

    quit(app)
  }

  func testComposerCommands() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    openSecondConversation(app)
    let composer = self.composer(app)

    // `/` shows the eleven commands, as the Help sheet lists them.
    composer.click()
    composer.typeText("/")
    let popup = element(app, "composer-commands")
    XCTAssertTrue(popup.waitForExistence(timeout: 5), app.debugDescription)
    for name in ["clear", "new", "voice", "model", "effort", "compact", "rename", "stop", "settings", "help", "btw"] {
      XCTAssertTrue(element(app, "command-\(name)").exists, "No /\(name) row")
    }
    // The eleventh row peeks above the popup's bottom edge, so the list reads as one that
    // scrolls; the live run saw ten whole rows and no /btw. A scroll brings it fully in.
    let btw = element(app, "command-btw")
    XCTAssertLessThan(btw.frame.minY, popup.frame.maxY - 4, "/btw at \(btw.frame) is hidden under \(popup.frame)")
    // A synthesized scroll sometimes does not reach the list (the frame did not move), so the
    // test scrolls again, up to three times, and waits for each to settle.
    for _ in 0..<3 where !btw.isHittable {
      popup.scroll(byDeltaX: 0, deltaY: -200)
      _ = btw.wait(for: \.isHittable, toEqual: true, timeout: 2)
    }
    XCTAssertTrue(btw.isHittable, "/btw is not hittable after a scroll: \(btw.frame) in \(popup.frame)")
    // Typing filters the list, and Tab completes the highlighted command and a space.
    composer.typeText("he")
    XCTAssertTrue(element(app, "command-clear").waitForNonExistence(timeout: 5))
    XCTAssertTrue(element(app, "command-help").exists)
    composer.typeKey(.tab, modifierFlags: [])
    waitForValue(composer, "/help ")
    XCTAssertTrue(element(app, "composer-commands").waitForNonExistence(timeout: 5))

    // /help opens the Help sheet, and the draft empties.
    composer.typeKey(.return, modifierFlags: [])
    let help = element(app, "help-sheet")
    XCTAssertTrue(help.waitForExistence(timeout: 10), app.debugDescription)
    app.windows["main"].sheets.buttons["Done"].click()
    XCTAssertTrue(help.waitForNonExistence(timeout: 10))
    waitForValue(composer, "")

    // /rename with a name renames at once. The fake Asks before it replies.
    composer.click()
    composer.typeText("/rename Renamed by command")
    composer.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(app.staticTexts["Rename needs an answer"].waitForExistence(timeout: 10))
    app.windows["main"].sheets.buttons["Go on"].click()
    waitUntilLogged(log, ["method": "rename", "args": ["fake-2", "Renamed by command"]])
    XCTAssertTrue(app.staticTexts["Renamed by command"].firstMatch.waitForExistence(timeout: 10))
    waitForValue(composer, "")

    // /rename alone opens the Rename sheet with the conversation's title in its field.
    composer.click()
    composer.typeText("/rename")
    composer.typeKey(.return, modifierFlags: [])
    let name = app.textFields["Conversation name"]
    XCTAssertTrue(name.waitForExistence(timeout: 10))
    XCTAssertEqual(name.value as? String, "Renamed by command")
    app.windows["main"].sheets.buttons["Cancel"].click()
    XCTAssertTrue(name.waitForNonExistence(timeout: 10))
    XCTAssertEqual(try Self.requests(log, "rename").count, 1)

    // /plugins is refused, sends nothing, and keeps the draft.
    composer.click()
    composer.typeKey("a", modifierFlags: .command)
    composer.typeText("/plugins")
    composer.typeKey(.return, modifierFlags: [])
    dismissAlert(
      app,
      "/plugins is not handled by Desktop. Use /help, or open Muse Code in the project inspector for CLI commands.")
    waitForValue(composer, "/plugins")
    XCTAssertTrue(try Self.requests(log, "send").isEmpty)

    quit(app)
  }

  func testMentionsAndAttachments() throws {
    let log = temporary.appending(path: "requests.jsonl")
    // Debug builds take these files in place of the open panel. The fake reads their sizes.
    let folder = temporary.appending(path: "attach")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let notes = folder.appending(path: "notes.txt")
    let picture = folder.appending(path: "picture.png")
    try Data("Some notes\n".utf8).write(to: notes)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
    let app = try launchFake(log: log, extra: ["MMAC_TEST_ATTACHMENTS": "\(notes.path):\(picture.path)"])
    openSecondConversation(app)
    let composer = self.composer(app)

    // `@` lists the project's top folder through `files`. A file inserts its path and a space.
    composer.click()
    composer.typeText("@")
    XCTAssertTrue(element(app, "composer-mentions").waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(element(app, "mention-src").waitForExistence(timeout: 5))
    XCTAssertTrue(element(app, "mention-notes.md").exists)
    composer.typeText("no")
    XCTAssertTrue(element(app, "mention-src").waitForNonExistence(timeout: 5))
    composer.typeKey(.tab, modifierFlags: [])
    waitForValue(composer, "@notes.md ")

    // A folder inserts its path and `/`, and the popup lists inside it.
    composer.typeText("@sr")
    XCTAssertTrue(element(app, "mention-src").waitForExistence(timeout: 10))
    composer.typeKey(.tab, modifierFlags: [])
    waitForValue(composer, "@notes.md @src/")
    XCTAssertTrue(element(app, "mention-src/app.swift").waitForExistence(timeout: 10))
    composer.typeKey(.return, modifierFlags: [])
    waitForValue(composer, "@notes.md @src/app.swift ")
    XCTAssertTrue(element(app, "composer-mentions").waitForNonExistence(timeout: 5))

    // The paperclip adds both files as chips.
    let attach = app.buttons["attach-button"]
    XCTAssertEqual(attach.label, "Attach images or text files")
    attach.click()
    waitUntilLogged(log, ["method": "attachments", "args": [[notes.path, picture.path]]])
    let notesChip = element(app, "attachment-chip-att-1")
    let pictureChip = element(app, "attachment-chip-att-2")
    XCTAssertTrue(notesChip.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(pictureChip.exists)
    // A chip's remove button removes that chip only.
    let remove = app.buttons["attachment-remove-att-1"]
    XCTAssertEqual(remove.label, "Remove notes.txt")
    remove.click()
    XCTAssertTrue(notesChip.waitForNonExistence(timeout: 10))
    waitUntilLogged(log, ["method": "remove-attachment", "args": ["att-1"]])
    XCTAssertTrue(pictureChip.exists)

    // A message sends the chip left, and the chip goes.
    composer.click()
    composer.typeKey("a", modifierFlags: .command)
    composer.typeText("With a file")
    composer.typeKey(.return, modifierFlags: [])
    let sent: NSDictionary = [
      "sessionId": "fake-2", "text": "With a file", "attachments": ["att-2"], "effort": "high", "mode": "queue",
    ]
    waitUntilLogged(log, ["method": "send", "args": [sent]])
    XCTAssertTrue(pictureChip.waitForNonExistence(timeout: 10))

    quit(app)
  }

  /// The microphone cannot run in a test: a click on an enabled mic button, or ⌥V while connected,
  /// would ask for it. So this test reaches only the states a disconnected backend allows, then
  /// checks that the button turns on once the backend connects, without clicking it.
  func testVoiceInputWithoutTheMicrophone() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log, extra: ["FAKE_BACKEND_OFFLINE": "1"])
    let status = app.buttons["Muse Code settings"]
    XCTAssertTrue(status.waitForExistence(timeout: 30), "The fake's requests: \(fakeRequests())")
    waitForValue(status, "Muse Code disconnected", timeout: 30)

    // Disconnected: the button is off.
    let button = app.buttons["voice-button"]
    XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertEqual(button.label, "Voice input (⌥V)")
    XCTAssertFalse(button.isEnabled)

    // ⌥V types no character and starts nothing.
    let composer = self.composer(app)
    composer.click()
    composer.typeText("Draft")
    app.typeKey("v", modifierFlags: .option)
    XCTAssertEqual(composer.value as? String, "Draft")
    XCTAssertFalse(element(app, "voice-status").exists)

    // /voice runs as a command while disconnected, and starts nothing either.
    composer.typeKey("a", modifierFlags: .command)
    composer.typeText("/voice")
    composer.typeKey(.return, modifierFlags: [])
    waitForValue(composer, "")
    XCTAssertFalse(element(app, "voice-status").waitForExistence(timeout: 2))
    XCTAssertTrue(try Self.requests(log, "voice").isEmpty)

    // Connected: the button turns on. It is not clicked.
    app.buttons["Reconnect"].click()
    waitUntilConnected(app)
    waitUntilEnabled(button)
    XCTAssertEqual(button.label, "Voice input (⌥V)")
    XCTAssertFalse(element(app, "voice-status").exists)

    quit(app)
    XCTAssertTrue(try Self.requests(log, "voice").isEmpty)
    XCTAssertTrue(try Self.requests(log, "cancel-voice").isEmpty)
  }

  func testTheInspectorFooterFollowsTheProject() throws {
    let log = temporary.appending(path: "requests.jsonl")
    // No recent project, so mMac starts on All projects.
    let app = try launchFake(log: log, extra: ["FAKE_BACKEND_NO_PROJECT": "1"])
    waitUntilConnected(app)

    let toggle = app.buttons["Toggle project inspector"]
    waitForValue(toggle, "Hidden")
    toggle.click()
    waitForValue(toggle, "Shown")
    // Window › Zoom fills the screen, so the footer is inside the window whatever size SwiftUI
    // opened it at.
    app.menuBars.menuBarItems["Window"].click()
    app.menuBars.menuItems["Zoom"].click()

    // No project: the three buttons show, and are off. None is clicked in this test.
    let finder = app.buttons["inspector-finder"]
    let terminal = app.buttons["inspector-terminal"]
    let museCode = app.buttons["inspector-muse-code"]
    XCTAssertTrue(finder.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(terminal.exists)
    XCTAssertTrue(museCode.exists)
    XCTAssertTrue(app.staticTexts["No project selected"].exists)
    for button in [finder, terminal, museCode] { XCTAssertFalse(button.isEnabled, "\(button) is enabled") }

    // A conversation in the project selects it: the three buttons turn on.
    let row = sidebarRow(app, "Second fake conversation")
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    XCTAssertTrue(app.staticTexts["The second conversation says hello."].waitForExistence(timeout: 10))
    for button in [finder, terminal, museCode] { waitUntilEnabled(button) }

    app.typeKey("i", modifierFlags: [.command, .option])
    waitForValue(toggle, "Hidden")

    quit(app)
    XCTAssertTrue(try Self.requests(log, "terminal").isEmpty)
    XCTAssertTrue(try Self.requests(log, "cli-terminal").isEmpty)
  }

  /// The live run's layout faults at the default 900-point window: Send cut at the right edge,
  /// the split view running past both window edges with the inspector open, the inspector's tabs
  /// past the right edge, and the Files tab widening the inspector until it ran past both of its
  /// edges, even after leaving Files. No Window › Zoom here: the default size is the point.
  func testTheWindowFitsAtItsDefaultWidth() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    waitUntilConnected(app)
    let window = app.windows["main"]
    // `launch` passes a 900-point frame in the argument domain, so a frame saved in Dom's own
    // defaults cannot change the width under test.
    XCTAssertEqual(window.frame.width, 900, accuracy: 1, "The window opened at \(window.frame)")

    // A new conversation in the fake's Git project: the worktree toggle is in the row too.
    let send = element(app, "send-button")
    XCTAssertTrue(send.waitForExistence(timeout: 10))
    assertInside(send, window, "Send")

    let toggle = app.buttons["Toggle project inspector"]
    waitForValue(toggle, "Hidden")
    toggle.click()
    waitForValue(toggle, "Shown")
    let tabs = element(app, "inspector-tabs")
    XCTAssertTrue(tabs.waitForExistence(timeout: 10), app.debugDescription)
    assertInside(tabs, window, "The inspector's tab bar")
    assertInside(app.buttons["New conversation"].firstMatch, window, "The sidebar's New conversation")
    assertInside(send, window, "Send, with the inspector open")

    // The Files tab: its rows and preview stay in the column, and the tab bar with them.
    selectTab(app, "Files")
    let notes = app.buttons["notes.md"]
    XCTAssertTrue(notes.waitForExistence(timeout: 10))
    assertInside(notes, window, "The Files row notes.md")
    assertInside(tabs, window, "The inspector's tab bar on Files")
    notes.click()
    let preview = app.textViews["file-preview"]
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    XCTAssertGreaterThan(preview.frame.width, 20, "The preview is \(preview.frame)")
    assertInside(preview, window, "The file preview")

    // Back on Changes, nothing stays wide.
    selectTab(app, "Changes")
    let changed = app.buttons["notes.md, Project root, Untracked"]
    XCTAssertTrue(changed.waitForExistence(timeout: 10))
    assertInside(changed, window, "The changed file notes.md")
    assertInside(tabs, window, "The inspector's tab bar back on Changes")
    assertInside(app.buttons["New conversation"].firstMatch, window, "The sidebar's New conversation after Files")
    assertInside(send, window, "Send after Files")

    // Off again, so the tests' own defaults suite ends with the inspector closed.
    app.typeKey("i", modifierFlags: [.command, .option])
    waitForValue(toggle, "Hidden")
    quit(app)
  }

  func testM5aAgainstTheFakeBackend() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    openFakeConversation(app)

    // Permission modes: the picker shows the fake's mode, and a pick travels.
    let mode = app.descendants(matching: .any)["mode-picker"]
    XCTAssertTrue(mode.waitForExistence(timeout: 5))
    mode.click()
    app.menuItems["On request"].click()

    // The session shell: `!echo hi` becomes a shell row.
    let composer = self.composer(app)
    composer.click()
    composer.typeText("!echo hi")
    composer.typeKey(.return, modifierFlags: [])
    let shellRow = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "$ echo hi")).firstMatch
    XCTAssertTrue(shellRow.waitForExistence(timeout: 10))

    // The changes badge opens the inspector on Changes.
    let badge = app.buttons["changes-badge"]
    XCTAssertTrue(badge.waitForExistence(timeout: 5))
    XCTAssertEqual(badge.label, "Changes +12 \u{2212}1")
    badge.click()
    let toggle = app.buttons["Toggle project inspector"]
    waitForValue(toggle, "Shown")
    // As the inspector test: fill the screen, so the six segments are inside the window.
    app.menuBars.menuBarItems["Window"].click()
    app.menuBars.menuItems["Zoom"].click()
    // A segmented segment reports its selection as its value, not as `isSelected`.
    let changesSelected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == 1"), object: tab(app, "Changes"))
    XCTAssertEqual(XCTWaiter().wait(for: [changesSelected], timeout: 5), .completed)

    // The context gauge, the Tasks tab and the Agents tab.
    XCTAssertTrue(app.staticTexts["Context 42%"].waitForExistence(timeout: 5))
    selectTab(app, "Tasks")
    let task = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Cleaning the build folder")).firstMatch
    XCTAssertTrue(task.waitForExistence(timeout: 10))
    selectTab(app, "Agents")
    let agent = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Count the files", "120 tokens")).firstMatch
    XCTAssertTrue(agent.waitForExistence(timeout: 10))
    agent.click()
    XCTAssertTrue(app.staticTexts["The second conversation says hello."].waitForExistence(timeout: 10))
    app.buttons["child-close"].click()

    // The Preview tab loads a page from disk and shows its title.
    selectTab(app, "Preview")
    let field = app.textFields["preview-url"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.click()
    field.typeText("file://" + repository.appending(path: "mac/Fixtures/preview.html").path)
    field.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(app.staticTexts["Fixture page"].waitForExistence(timeout: 15))

    // The file context menu: Copy › Relative path. The pasteboard is Dom's; it goes back after.
    selectTab(app, "Files")
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
    let notes = app.buttons["notes.md"]
    XCTAssertTrue(notes.waitForExistence(timeout: 10))
    notes.rightClick()
    // The row's context menu, not the menu bar's Edit menu, which also has a Copy item: the
    // context menu opens last, so its Copy is the last match.
    let copies = app.menuItems.matching(NSPredicate(format: "title == %@", "Copy"))
    XCTAssertTrue(copies.firstMatch.waitForExistence(timeout: 5))
    copies.element(boundBy: copies.count - 1).click()
    let relative = app.menuItems.matching(NSPredicate(format: "title == %@", "Relative path")).firstMatch
    XCTAssertTrue(relative.waitForExistence(timeout: 10))
    relative.click()
    XCTAssertEqual(board.string(forType: .string), "notes.md")

    // Side chat: ⌘; opens the sheet on the fake's side session; Close dismisses it.
    app.typeKey(";", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["The side says hello."].waitForExistence(timeout: 10))
    let question = app.textFields["side-chat-field"]
    question.click()
    question.typeText("Why that file?")
    question.typeKey(.return, modifierFlags: [])
    app.buttons["side-chat-close"].click()
    XCTAssertTrue(app.staticTexts["The side says hello."].waitForNonExistence(timeout: 10))

    // Keyboard parity: ⌘⇧] opens the next conversation, ⌘⇧[ comes back.
    app.typeKey("]", modifierFlags: [.command, .shift])
    XCTAssertTrue(app.staticTexts["The second conversation says hello."].waitForExistence(timeout: 10))
    app.typeKey("[", modifierFlags: [.command, .shift])
    XCTAssertTrue(shellRow.waitForExistence(timeout: 10))

    // Off again, so the tests' own defaults suite ends with the inspector closed.
    app.typeKey("i", modifierFlags: [.command, .option])
    waitForValue(toggle, "Hidden")
    quit(app)

    let entries = try Self.logged(log)
    assertLogged(entries, ["method": "set-approval-mode", "args": ["fake-1", "onRequest"]])
    assertLogged(entries, ["method": "shell", "args": ["fake-1", "echo hi"]])
    assertLogged(entries, ["method": "side-chat", "args": ["fake-1"]])
    assertLogged(entries, ["method": "open", "args": ["fake-2"]])
    XCTAssertTrue(
      entries.contains {
        $0["method"] as? String == "send" && (($0["args"] as? [Any])?.first as? [String: Any])?["sessionId"] as? String == "fake-side"
      })
  }

  func testM5bAgainstTheFakeBackend() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    let project = temporary.appending(path: "project").path
    waitUntilConnected(app)

    // Usage: the footer line, as VoiceOver reads it, and its popover.
    let footer = app.buttons["usage-footer"]
    XCTAssertTrue(footer.waitForExistence(timeout: 10), "No usage footer. The fake's requests: \(fakeRequests())")
    XCTAssertEqual(footer.label, "Usage limits")
    waitForValue(footer, "5-hour 85 percent, week 30 percent")
    footer.click()
    let session = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Session limit 85 percent used")).firstMatch
    XCTAssertTrue(session.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(session.waitForNonExistence(timeout: 5))

    // The stop banner on the second conversation, and its line about what happens next. On macOS a
    // SwiftUI Text can report its string as its value, so the predicates check both.
    let second = sidebarRow(app, "Second fake conversation")
    XCTAssertTrue(second.waitForExistence(timeout: 10))
    second.click()
    let banner = app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Session limit reached. Resets",
          "Session limit reached. Resets")
      ).firstMatch
    XCTAssertTrue(banner.waitForExistence(timeout: 10))
    let saved = "Your conversation is saved. mMac can send again after the reset."
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@ OR value == %@", saved, saved)).firstMatch.exists)

    // Settings › Scheduled: pause one task, run the other.
    app.typeKey(",", modifierFlags: .command)
    let settings = settingsWindow(app)
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    pane(settings, "Scheduled").click()
    let active = settings.descendants(matching: .any)["schedule-active-b"]
    XCTAssertTrue(active.waitForExistence(timeout: 10))
    active.click()
    waitUntilLogged(log, ["method": "schedule-enabled", "args": ["b", false]])
    let run = settings.buttons["schedule-run-a"]
    XCTAssertTrue(run.waitForExistence(timeout: 5))
    run.click()
    waitUntilLogged(log, ["method": "schedule-run", "args": ["a"]])
    settings.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(settings.waitForNonExistence(timeout: 5))

    // Proposed changes: card 1 is ready, card 2 waits for it.
    let proposed = app.buttons["proposed-changes"]
    XCTAssertTrue(proposed.waitForExistence(timeout: 5))
    proposed.click()
    let card1 = app.descendants(matching: .any)["change-card-1"]
    XCTAssertTrue(card1.waitForExistence(timeout: 10), "No card 1. The fake's requests: \(fakeRequests())")
    XCTAssertTrue(
      card1.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", "Ready for you")).firstMatch.waitForExistence(timeout: 5))
    let card2 = app.descendants(matching: .any)["change-card-2"]
    XCTAssertTrue(card2.waitForExistence(timeout: 5))
    XCTAssertTrue(
      card2.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Accept PR 1 first", "Accept PR 1 first"))
        .firstMatch.exists)

    // Accept card 1: the backend Asks first. The Ask is a sheet on the Proposed changes sheet.
    let accept = app.buttons["change-accept-1"]
    XCTAssertEqual(accept.label, "Accept PR 1")
    waitUntilEnabled(accept)
    accept.click()
    XCTAssertTrue(app.staticTexts["Accept pull request 1?"].waitForExistence(timeout: 10))
    let answer = app.windows["main"].sheets.sheets.buttons["Accept"]
    XCTAssertTrue(answer.waitForExistence(timeout: 5))
    answer.click()
    waitUntilLogged(log, ["answer": 3, "choice": 0])
    XCTAssertTrue(
      card1.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", "Accepted")).firstMatch.waitForExistence(timeout: 10))
    // AppKit does not quit while a window has a sheet attached, so the sheet closes first.
    let sheet = element(app, "proposed-changes-sheet")
    app.windows["main"].sheets.buttons["Done"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    quit(app)

    let entries = try Self.logged(log)
    assertLogged(entries, ["method": "pr-merge", "args": [project, 1]])
    assertLogged(entries, ["method": "open", "args": ["fake-2"]])
  }
}
