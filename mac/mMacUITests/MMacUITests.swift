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
    app.launchArguments = [
      "-MMacRepository", repository.path, "-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES",
    ]
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

  /// Waits until the sidebar's status, a button that opens Settings, reads "Connected to Muse Code".
  private func waitUntilConnected(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let status = app.buttons["Muse Code settings"]
    XCTAssertTrue(status.waitForExistence(timeout: 30), file: file, line: line)
    waitForValue(status, "Connected to Muse Code", timeout: 30, file: file, line: line)
  }

  /// Opens the fake conversation and presses Escape on the Ask it raises first. Escape must choose
  /// the last button.
  private func openFakeConversation(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    waitUntilConnected(app, file: file, line: line)
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
    try logged(log).compactMap { $0 }.filter { $0["method"] as? String == method }
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
    waitUntilConnected(app)

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
    XCTAssertTrue(entries.contains { $0?["method"] as? String == "shutdown" })
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
    XCTAssertTrue(app.staticTexts["4 lines"].exists)
    app.buttons["Ask Muse"].firstMatch.click()
    let composer = app.descendants(matching: .any)["composer"]
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

    // Off again from the View menu's shortcut. A run of these tests must leave the real defaults
    // as they were, even after the inspector closes.
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

    // Appearance: each choice saves on its own.
    pane(settings, "Appearance").click()
    let moonlight = settings.buttons["theme-moonlight"]
    XCTAssertTrue(moonlight.waitForExistence(timeout: 10), settings.debugDescription)
    moonlight.click()
    waitUntilLogged(log, ["method": "preferences", "args": [["theme": "moonlight"]]])
    settings.radioButtons["Large"].click()
    waitUntilLogged(log, ["method": "preferences", "args": [["fontSize": "large"]]])
    let saved = try Self.requests(log, "preferences").suffix(2).map { $0["args"] as? NSArray }
    XCTAssertEqual(saved, [[["theme": "moonlight"]], [["fontSize": "large"]]])

    // Muse Code: its path field sits in a `LabeledContent`, and reading the pane's elements must
    // not loop the field's label.
    pane(settings, "Muse Code").click()
    let cliPath = settings.textFields["cli-path"]
    XCTAssertTrue(cliPath.waitForExistence(timeout: 10))
    XCTAssertEqual(cliPath.label, "Custom executable path")
    XCTAssertTrue(settings.buttons["Reconnect to Muse Code"].exists)

    // MCP servers: add a local server.
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

    // Remove asks first. Cancel keeps the server.
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

    // Bridges: a token, shown once, then the MCP bridge on.
    pane(settings, "Bridges").click()
    let makeToken = settings.buttons["bridge-make-token"]
    XCTAssertTrue(makeToken.waitForExistence(timeout: 10))
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

    // A refused port typed without Return, then left by switching panes, raises no alert.
    let port = settings.textFields["bridge-port"]
    XCTAssertEqual(port.value as? String, "7735")
    port.click()
    port.typeKey("a", modifierFlags: .command)
    port.typeText("80")
    pane(settings, "Appearance").click()
    XCTAssertTrue(settings.buttons["theme-moonlight"].waitForExistence(timeout: 5))
    let alert = app.staticTexts["Use a port between 1024 and 65535."]
    XCTAssertFalse(alert.waitForExistence(timeout: 3), app.debugDescription)
    XCTAssertFalse(settings.sheets.firstMatch.exists)
    XCTAssertTrue(
      try Self.requests(log, "preferences").allSatisfy { (($0["args"] as? NSArray)?.firstObject as? NSDictionary)?["bridgeMcpPort"] == nil })

    quit(app)
  }

  func testARestartReopensTheConversationWithItsDraft() throws {
    let log = temporary.appending(path: "requests.jsonl")
    let app = try launchFake(log: log)
    openFakeConversation(app)
    let composer = app.descendants(matching: .any)["composer"]

    // A draft in the second conversation.
    app.staticTexts["Second fake conversation"].firstMatch.click()
    XCTAssertTrue(app.staticTexts["The second conversation says hello."].waitForExistence(timeout: 10))
    composer.click()
    composer.typeText("A draft to keep")
    XCTAssertEqual(composer.value as? String, "A draft to keep")

    // The third conversation sends the message that stops the fake.
    app.staticTexts["Third fake conversation"].firstMatch.click()
    XCTAssertTrue(app.staticTexts["The third conversation says hello."].waitForExistence(timeout: 10))
    XCTAssertEqual(composer.value as? String, "")
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
    XCTAssertEqual(try Self.requests(log, "open").last?["args"] as? NSArray, ["fake-3"])
    app.staticTexts["Second fake conversation"].firstMatch.click()
    XCTAssertTrue(app.staticTexts["The second conversation says hello."].waitForExistence(timeout: 10))
    XCTAssertEqual(composer.value as? String, "A draft to keep")

    quit(app)
  }
}
