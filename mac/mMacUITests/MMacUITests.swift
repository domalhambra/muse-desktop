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
    return app
  }

  private func quit(_ app: XCUIApplication) {
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "mMac did not quit within 15 seconds")
  }

  func testAnEchoConversationEndToEnd() throws {
    let muse = try XCTUnwrap(
      ProcessInfo.processInfo.environment["MUSE_BIN"],
      #"Run with TEST_RUNNER_MUSE_BIN="$(command -v muse)"."#)
    let app = try launch(cliPath: muse)
    XCTAssertTrue(app.staticTexts["Connected to Muse Code"].waitForExistence(timeout: 30))

    let composer = app.descendants(matching: .any)["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.click()
    composer.typeText("Check this")
    for line in ["```swift", "let x = 1", "```"] {
      composer.typeKey(.return, modifierFlags: .shift)
      composer.typeText(line)
    }
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
    let app = try launch(
      cliPath: "",
      extra: [
        "MMAC_BACKEND_SCRIPT": repository.appending(path: "mac/Fixtures/fake-backend.mjs").path,
        "FAKE_BACKEND_LOG": log.path,
      ])
    XCTAssertTrue(app.staticTexts["Connected to Muse Code"].waitForExistence(timeout: 30))

    let row = app.staticTexts["Fake conversation"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()

    // The fake Asks before it opens. Escape must choose the last button.
    XCTAssertTrue(app.staticTexts["Open the fake conversation?"].waitForExistence(timeout: 10))
    app.typeKey(.escape, modifierFlags: [])

    XCTAssertTrue(app.staticTexts["Approval required"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Muse would like permission to use shell."].exists)
    XCTAssertTrue(app.staticTexts["Saves a rule"].exists)
    app.buttons["Allow once"].click()
    XCTAssertTrue(app.buttons["Allow once"].waitForNonExistence(timeout: 10))

    XCTAssertTrue(app.staticTexts["Input required"].exists)
    XCTAssertFalse(app.buttons["Continue"].isEnabled)
    app.buttons["Blue"].click()
    XCTAssertTrue(app.buttons["Continue"].isEnabled)
    app.buttons["Continue"].click()
    XCTAssertTrue(app.staticTexts["Input required"].waitForNonExistence(timeout: 10))

    let picker = app.descendants(matching: .any)["model-picker"]
    XCTAssertTrue(picker.exists)
    picker.click()
    app.menuItems["Fake Model Two"].click()

    quit(app)

    let entries = try String(contentsOf: log, encoding: .utf8)
      .split(separator: "\n")
      .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }
    func logged(_ expected: NSDictionary) -> Bool { entries.contains { $0 == expected } }
    XCTAssertTrue(logged(["answer": 1, "choice": 1]))
    XCTAssertTrue(logged(["method": "approve", "args": ["fake-1", "appr-1", "once"]]))
    XCTAssertTrue(
      logged(["method": "answer", "args": ["fake-1", "ask-1", [["questionId": "color", "selectedLabel": "Blue"]]]]))
    XCTAssertTrue(logged(["method": "set-model", "args": ["fake-1", "fake-two"]]))
    XCTAssertTrue(entries.contains { $0?["method"] as? String == "shutdown" })
  }
}
