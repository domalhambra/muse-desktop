import AppKit
import MuseKit
import SwiftUI
import os

@main
struct MMacApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  static let mainWindow = "main"

  /// Whether `window` is the conversation window. SwiftUI names it by its scene's id. The Settings
  /// window can become main too, so "main" in AppKit's sense does not tell them apart.
  @MainActor static func isMainWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue == mainWindow
  }

  #if DEBUG || MMAC_MEASURE
    /// The UI tests' own defaults suite, from `MMAC_DEFAULTS_SUITE`. Debug builds only; nil when
    /// the variable is unset or empty. The size measurement's build (`MMAC_MEASURE`) always has
    /// one, `com.domalhambra.mmac.measure` unless the variable names another, so it never writes
    /// Dom's defaults.
    static let testDefaultsSuite: String? = {
      guard let suite = ProcessInfo.processInfo.environment["MMAC_DEFAULTS_SUITE"], !suite.isEmpty else {
        #if MMAC_MEASURE
          return "com.domalhambra.mmac.measure"
        #else
          return nil
        #endif
      }
      return suite
    }()
  #endif

  /// Where `@AppStorage` keeps the window's choices, such as `inspectorShown`. Debug builds take
  /// `MMAC_DEFAULTS_SUITE` from the UI tests: a suite of their own, emptied at launch, so a test
  /// starts from the defaults and never reads or changes Dom's. The test runner is sandboxed and
  /// cannot reach mMac's preferences itself.
  static let appStorage: UserDefaults = {
    #if DEBUG || MMAC_MEASURE
      if let suite = testDefaultsSuite, let defaults = UserDefaults(suiteName: suite) {
        defaults.removePersistentDomain(forName: suite)
        return defaults
      }
    #endif
    return .standard
  }()

  /// False in Debug builds run with `MMAC_DEFAULTS_SUITE`, as the UI tests run them. AppKit keeps
  /// the windows' frames ("NSWindow Frame main", "NSWindow Frame com_apple_SwiftUI_Settings_window")
  /// and the sidebar's width ("NSSplitView Subview Frames main, SidebarNavigationSplitView") in the
  /// standard defaults, not in `appStorage`, so such a run turns those saves off instead: see
  /// `WindowStateGuard`.
  static let keepsWindowState: Bool = {
    #if DEBUG || MMAC_MEASURE
      if testDefaultsSuite != nil { return false }
    #endif
    return true
  }()

  var body: some Scene {
    // One window. The backend belongs to the app, so closing this window keeps it.
    Window("mMac", id: Self.mainWindow) {
      RootView(controller: delegate.controller)
        .frame(minWidth: WindowMetrics.windowMinWidth, minHeight: WindowMetrics.windowMinHeight)
        .themed(delegate.controller)
        .defaultAppStorage(Self.appStorage)
    }
    .defaultSize(width: WindowMetrics.defaultWidth, height: WindowMetrics.defaultHeight)
    // A test run does not reopen its window at the next launch.
    .restorationBehavior(Self.keepsWindowState ? .automatic : .disabled)
    .commands {
      CommandGroup(replacing: .newItem) {
        FileCommands(controller: delegate.controller)
      }
      CommandGroup(after: .sidebar) {
        CommandMenuCommand(controller: delegate.controller)
        InspectorCommand()
        SideChatCommand(controller: delegate.controller)
        ConversationCommands(controller: delegate.controller)
        PickerCommands(controller: delegate.controller)
      }
      CommandGroup(replacing: .help) {
        HelpCommand(controller: delegate.controller)
      }
      // Edit › Voice Input, then Edit › Find, for the find bars of the file preview and of stored output.
      CommandGroup(after: .textEditing) {
        VoiceCommand(controller: delegate.controller)
        Menu("Find") {
          Button("Find…") { TextFinder.send(.showFindInterface) }.keyboardShortcut("f")
          Button("Find Next") { TextFinder.send(.nextMatch) }.keyboardShortcut("g")
          Button("Find Previous") { TextFinder.send(.previousMatch) }
            .keyboardShortcut("g", modifiers: [.command, .shift])
          Button("Use Selection for Find") { TextFinder.send(.setSearchString) }.keyboardShortcut("e")
        }
      }
    }
    // mMac › Settings… (Command-comma). Its panes show only while a backend runs.
    Settings {
      SettingsView(controller: delegate.controller)
        .defaultAppStorage(Self.appStorage)
        .themed(delegate.controller)
        .background { if !Self.keepsWindowState { WindowStateGuard() } }
    }
  }
}

/// The File menu's items. A view, so its `disabled` states follow the controller as it changes.
private struct FileCommands: View {
  let controller: AppController

  var body: some View {
    // Both bring the window forward first, opening it when it is closed, so the result and the
    // open panel show there even when Settings is in front.
    Button("New conversation") {
      controller.showMainWindow()
      controller.workspace?.startNew()
    }
    .keyboardShortcut("n")
    .disabled(controller.workspace == nil)
    Button("Open project…") {
      controller.showMainWindow()
      Task { await controller.openProject() }
    }
    .keyboardShortcut("o")
    .disabled(controller.workspace == nil)
  }
}

/// View → Show Inspector. It shares the stored choice with the toolbar button.
private struct InspectorCommand: View {
  // The store is named here: a menu item does not reliably read the window's `defaultAppStorage`.
  @AppStorage("inspectorShown", store: MMacApp.appStorage) private var inspectorShown = false

  var body: some View {
    Button(inspectorShown ? "Hide Inspector" : "Show Inspector") { inspectorShown.toggle() }
      .keyboardShortcut("i", modifiers: [.command, .option])
  }
}

/// View → Command Menu. ⌘K only opens it, as in Electron: a second press while it shows does nothing.
/// It waits while another sheet is up on the main window: the Rename and Help sheets disable the item, and
/// AppKit's panels and alerts (an export or open panel, an Ask), which SwiftUI cannot observe, make
/// the press do nothing.
private struct CommandMenuCommand: View {
  let controller: AppController

  var body: some View {
    Button("Command Menu") {
      let main = NSApp.windows.first(where: { $0.isVisible && MMacApp.isMainWindow($0) })
      guard main?.attachedSheet == nil else { return }
      controller.showMainWindow()
      // A result left from a sheet that closed without running it must not run on the next close.
      controller.sheets.chosen = nil
      controller.sheets.commandMenu = true
    }
    .keyboardShortcut("k")
    .disabled(controller.workspace == nil || controller.sheets.renaming || controller.sheets.help)
  }
}

/// Edit → Voice Input (⌥V): starts or stops voice input from anywhere in the conversation window,
/// as Electron's window-wide Option-V. A menu key equivalent, so the composer never types "√".
private struct VoiceCommand: View {
  private static let log = Logger(subsystem: "com.domalhambra.mmac", category: "voice")
  let controller: AppController

  var body: some View {
    Button("Voice Input") {
      let connected = controller.workspace?.isConnected == true ? "connected" : "disconnected"
      let phase = controller.voice.map { "\($0.phase), \(connected)" } ?? "no voice session"
      guard canRun, let voice = controller.voice else {
        Self.log.debug("Voice Input: \(phase, privacy: .public), not run")
        return
      }
      Self.log.debug("Voice Input: \(phase, privacy: .public), toggled")
      Task { await voice.toggle() }
    }
    .keyboardShortcut("v", modifiers: .option)
    // On whenever a Workspace exists. When voice cannot run, the press does nothing, as Electron's
    // handler prevents the default and its toggle returns early. A focused text view gets ⌥V
    // before the menu, so the composer hands the key here itself (`ComposerTextView.keyDown`).
    .disabled(controller.voice == nil)
  }

  /// Only in the conversation window, and not over one of its sheets: Electron ignores Option-V
  /// while a dialog is open. A sheet is the key window while it shows; the checks on
  /// `attachedSheet` and `anyShown` are the ones ⌘K and the composer's popups use. Then as the mic
  /// button: idle needs the connection and no send in flight; a recording can always stop.
  private var canRun: Bool {
    guard let voice = controller.voice, let workspace = controller.workspace,
      let window = NSApp.keyWindow, MMacApp.isMainWindow(window), window.attachedSheet == nil,
      !controller.sheets.anyShown
    else { return false }
    switch voice.phase {
    case .idle: return workspace.isConnected && !workspace.submitting
    case .recording: return true
    case .permission, .transcribing: return false
    }
  }
}

/// Sends a find action down the responder chain, as AppKit's own Find menu items do: the action
/// is the sender's tag. Only a text view with a find bar takes it. `ReadOnlyTextView` has one; the
/// composer and the Settings fields have none, so there the items do nothing, as in Electron.
@MainActor enum TextFinder {
  static func send(_ action: NSTextFinder.Action) {
    let selector = #selector(NSResponder.performTextFinderAction(_:))
    let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
    item.tag = action.rawValue
    // NSTextView refuses the action unless it uses a find bar or panel, as AppKit's own menu
    // validation would.
    guard let target = NSApp.target(forAction: selector, to: nil, from: item) else { return }
    if let validating = target as? NSUserInterfaceValidations, !validating.validateUserInterfaceItem(item) { return }
    NSApp.sendAction(selector, to: target, from: item)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let controller = AppController()
  /// True from `.terminateLater` until its one reply.
  private var replyPending = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await controller.start() }
  }

  /// Closing the window keeps mMac and its backend running, so a turn is never cut off unasked.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// A Dock click reopens the conversation window when it is closed, even with Settings open.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    !controller.revealWindow()
  }

  /// Quits after the backend has closed `muse serve`, or when the person chose to keep working.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if replyPending {
      // A second Quit while the backend has not answered: stop it now. The first Quit then replies.
      controller.forceQuit()
      return .terminateCancel
    }
    replyPending = true
    Task {
      let quit = await controller.quit()
      replyPending = false
      sender.reply(toApplicationShouldTerminate: quit)
    }
    return .terminateLater
  }
}

/// View › Side Chat (⌘;): a question beside the open conversation, as Desktop's side chat.
private struct SideChatCommand: View {
  let controller: AppController

  var body: some View {
    Button("Side Chat") {
      controller.showMainWindow()
      controller.sheets.sideChat = true
    }
    .keyboardShortcut(";")
    .disabled(controller.workspace?.view == nil || controller.sheets.anyShown)
  }
}

/// View › Next and Previous Conversation (⌘⇧] and ⌘⇧[), as Desktop's session cycling. One shortcut
/// per item: Ctrl+Tab is left to the system.
private struct ConversationCommands: View {
  let controller: AppController

  var body: some View {
    Button("Next Conversation") { Task { await controller.workspace?.openNeighbor(forward: true) } }
      .keyboardShortcut("]", modifiers: [.command, .shift])
      .disabled(controller.workspace == nil)
    Button("Previous Conversation") { Task { await controller.workspace?.openNeighbor(forward: false) } }
      .keyboardShortcut("[", modifiers: [.command, .shift])
      .disabled(controller.workspace == nil)
  }
}

/// View › Model…, Reasoning Effort… and Mode… (⌘⇧I, ⌘⇧E, ⌘⇧M): open the composer's pickers.
private struct PickerCommands: View {
  let controller: AppController

  var body: some View {
    Button("Model…") { PickerOpener.open("model-picker") }
      .keyboardShortcut("i", modifiers: [.command, .shift])
      .disabled(controller.workspace == nil)
    Button("Reasoning Effort…") { PickerOpener.open("effort-picker") }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(controller.workspace == nil)
    Button("Mode…") { PickerOpener.open("mode-picker") }
      .keyboardShortcut("m", modifiers: [.command, .shift])
      .disabled(controller.workspace?.view == nil)
  }
}

/// Help › Keyboard Shortcuts (⌘/): the Help sheet, which /help opens too.
private struct HelpCommand: View {
  let controller: AppController

  var body: some View {
    Button("Keyboard Shortcuts") {
      controller.showMainWindow()
      controller.sheets.help = true
    }
    .keyboardShortcut("/")
    .disabled(controller.workspace == nil || controller.sheets.anyShown)
  }
}
