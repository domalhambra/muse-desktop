import AppKit
import MuseBackend
import MuseKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer, as Electron's `Composer.tsx`.
struct ComposerView: View {
  let controller: AppController
  @Bindable var workspace: Workspace
  @Environment(\.appearance) private var appearance
  @Environment(\.openSettings) private var openSettings
  // The store is named here, as the sidebar and banner name it, so all of them share one value.
  @AppStorage(SettingsView.paneKey, store: MMacApp.appStorage) private var settingsPane: SettingsView.Pane = .appearance
  /// The text area's height, which it measures itself.
  @State private var inputHeight: CGFloat = 17
  /// A choice still being saved. The picker shows it until the Workspace answers, then shows the
  /// real value again, so a failed change does not leave the popup showing it.
  @State private var pendingModel: String?
  @State private var pendingEffort: String?
  @State private var pendingMode: String?
  /// The highlighted row of the slash popup and of the @ popup. Both go back to the first row when
  /// the draft changes, as in Electron.
  @State private var commandIndex = 0
  @State private var mentionIndex = 0
  /// The folder listing behind the @ popup, and the Workspace it lists for. A restarted backend
  /// brings a new Workspace, and with it a new menu.
  @State private var mentionMenu: MentionMenu?
  @State private var mentionOwner: ObjectIdentifier?
  /// Bumped after a popup rewrites the draft, so the text area takes focus with the cursor at the end.
  @State private var cursorRequest = 0
  /// A file drag is over the text view, or over the rest of the composer. Each has its own flag,
  /// so a late "exited" from one does not hide the ring while the drag is over the other.
  @State private var draggingOverText = false
  @State private var draggingOverComposer = false

  var body: some View {
    @Bindable var sheets = controller.sheets
    // Read once per render: the popups use the same lists the keys do.
    let commands = showsPopups ? ComposerCommand.menu(for: workspace.draft) : []
    let mention = draftMention
    let mentionRows = showsPopups && commands.isEmpty ? (mentionMenu?.rows(for: workspace.draft) ?? []) : []
    VStack(alignment: .leading, spacing: 8) {
      if workspace.isRunning { runningBar }
      if !workspace.attachments.isEmpty { AttachmentChips(workspace: workspace) }
      ComposerTextView(
        text: $workspace.draft, height: $inputHeight, placeholder: placeholder,
        placeholderColor: NSColor(appearance.colors.muted),
        isEnabled: workspace.composerIsEditable, focusRequest: workspace.composerFocusRequest,
        cursorRequest: cursorRequest, onSubmit: submit, onPopupKey: popupKey,
        onDropFiles: { urls in Task { await workspace.drop(urls) } },
        onDragChange: { draggingOverText = $0 },
        // As a drop: a pasted folder inside the project becomes a mention.
        onPasteFiles: { urls in Task { await workspace.drop(urls) } },
        onPasteImage: { data in Task { await workspace.attachPasted(data, type: UTType.png.identifier) } }
      )
      .frame(height: inputHeight)
      .padding(10)
      .background(appearance.colors.input, in: RoundedRectangle(cornerRadius: 8))
      // Electron's `is-dragging` ring.
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(appearance.colors.accent, lineWidth: draggingOverText || draggingOverComposer ? 2 : 0))
      .overlay(alignment: .top) {
        popup(commands: commands, mentionRows: mentionRows)
          // Above the field, 10 points clear, as Electron's `.slash-menu`.
          .alignmentGuide(.top) { $0[.bottom] + 10 }
      }
      HStack(spacing: 10) {
        AttachButton(workspace: workspace)
        Divider().frame(height: 16)
        if let voice = controller.voice {
          VoiceButton(voice: voice, workspace: workspace)
        }
        Picker("Model", selection: modelSelection) {
          if !workspace.models.contains(where: { $0.modelId == workspace.modelId }) {
            Text(workspace.modelId.isEmpty ? "CLI default" : workspace.modelId).tag(workspace.modelId)
          }
          ForEach(workspace.models) { model in
            Text(model.displayLabel.isEmpty ? model.modelId : model.displayLabel).tag(model.modelId)
          }
        }
        .fixedSize()
        // The stock bezel: the theme's light accent under a white label is unreadable.
        .tint(nil)
        .disabled(workspace.submitting || workspace.models.isEmpty)
        .accessibilityIdentifier("model-picker")
        Picker("Reasoning effort", selection: effortSelection) {
          ForEach(ReasoningEffort.allCases) { effort in Text(effort.label).tag(effort.rawValue) }
          // A newer CLI's effort that this list does not know still shows, including one being
          // saved, which the picker shows until the save ends.
          let shown = pendingEffort ?? workspace.effort
          if ReasoningEffort(rawValue: shown) == nil {
            Text(shown).tag(shown)
          }
        }
        .fixedSize()
        .tint(nil)
        .accessibilityIdentifier("effort-picker")
        Picker("Mode", selection: modeSelection) {
          ForEach(ApprovalMode.allCases) { mode in Text(mode.label).tag(mode.rawValue) }
          // A newer CLI's mode, or none yet (a new conversation), still has a row.
          let shown = pendingMode ?? workspace.approvalMode
          if ApprovalMode(rawValue: shown) == nil {
            Text(shown.isEmpty ? "Mode" : ApprovalMode.label(for: shown)).tag(shown)
          }
        }
        .fixedSize()
        .tint(nil)
        .disabled(workspace.view == nil || workspace.submitting)
        .help("How much Muse may do without asking. A change applies to Muse\u{2019}s next action.")
        .accessibilityIdentifier("mode-picker")
        if workspace.canStartInWorktree {
          let label =
            workspace.startInWorktree
            ? "Starts in a new Git worktree (click to use the project folder)"
            : "Start in a new Git worktree"
          Toggle(isOn: $workspace.startInWorktree) {
            Image(systemName: "arrow.triangle.branch")
          }
          .toggleStyle(.button)
          .disabled(workspace.submitting)
          .accessibilityLabel(label)
          .help(label)
        }
        Spacer()
        Text("↵ Send · ⇧ ↵ New line").font(.caption).foregroundStyle(.themeMuted)
        Button(action: submit) {
          if workspace.submitting {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "arrow.up.circle.fill").font(.title2)
          }
        }
        .buttonStyle(.borderless)
        .disabled(!canSend)
        .accessibilityLabel(workspace.isRunning ? "Send follow-up" : "Send message")
        .accessibilityIdentifier("send-button")
        .help(workspace.isRunning ? "Send follow-up" : "Send message")
      }
      // On its own line, so a long note does not squeeze the row.
      if let footnote {
        Text(footnote)
          .font(.caption)
          .foregroundStyle(.themeSecondary)
          .accessibilityIdentifier("composer-footnote")
      }
    }
    .padding(12)
    // A drop outside the text lands here; the text view takes its own through `onDropFiles`.
    // File URLs only, so a web link dragged over the composer neither lights the ring nor drops.
    .onDrop(of: [.fileURL], isTargeted: $draggingOverComposer) { providers in
      guard workspace.composerIsEditable else { return false }
      Task {
        var urls: [URL] = []
        for provider in providers {
          if let url = await Self.fileURL(provider) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        await workspace.drop(urls)
      }
      return true
    }
    .onChange(of: workspace.draft) {
      commandIndex = 0
      mentionIndex = 0
    }
    // As Electron's mention effect: the folder is read when the project, the mention's folder or
    // whether a mention is typed changes. Typing within the folder filters what was read. Not on
    // every keystroke: a task keyed on the draft would cancel a listing still in flight.
    .task(
      id: MentionFolder(
        workspace: ObjectIdentifier(workspace), project: workspace.project, directory: mention?.directory)
    ) {
      if mentionOwner != ObjectIdentifier(workspace) {
        mentionMenu = MentionMenu(workspace: workspace)
        mentionOwner = ObjectIdentifier(workspace)
      }
      await mentionMenu?.update(draft: workspace.draft)
    }
  }

  /// The file URL a dropped item carries, or nil.
  private static func fileURL(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        continuation.resume(returning: url?.isFileURL == true ? url : nil)
      }
    }
  }

  /// What the mention task is keyed on. A nil folder means no mention is typed.
  private struct MentionFolder: Equatable {
    let workspace: ObjectIdentifier
    let project: String
    let directory: String?
  }

  @ViewBuilder private func popup(commands: [ComposerCommand], mentionRows: [ProjectFile]) -> some View {
    if !commands.isEmpty {
      SlashCommandMenu(commands: commands, selected: commandIndex) { index in
        // A click does what Tab does on that row.
        if case .setDraft(let text) = ComposerCommand.slashKeyAction(.tab, draft: workspace.draft, index: index) {
          setDraft(text)
        }
      }
    } else if !mentionRows.isEmpty {
      MentionList(files: mentionRows, selected: min(mentionIndex, mentionRows.count - 1)) { index in
        chooseMention(mentionRows[index])
      }
    }
  }

  /// No popup and no popup keys while a window sheet shows (the sheet has the keys then), or while
  /// a conversation opens (the composer is read-only then).
  private var showsPopups: Bool { !controller.sheets.anyShown && workspace.composerIsEditable }

  /// The @ mention at the end of the draft. Only with a project, as in Electron.
  private var draftMention: Mention? {
    workspace.project.isEmpty ? nil : MentionRule.match(workspace.draft)
  }

  /// Up, Down, Tab, Return and Escape while a popup shows, as Electron's composer handles them.
  /// False leaves the key to the text area: Return on a complete command name sends it.
  private func popupKey(_ key: SlashKey) -> Bool {
    guard showsPopups else { return false }
    let draft = workspace.draft
    if !ComposerCommand.menu(for: draft).isEmpty {
      switch ComposerCommand.slashKeyAction(key, draft: draft, index: commandIndex) {
      case .pass, .submit: return false
      case .select(let index): commandIndex = index
      case .setDraft(let text): setDraft(text)
      }
      return true
    }
    let rows = mentionMenu?.rows(for: draft) ?? []
    // `keyAction` clamps the index: the rows can shrink under the highlight when a listing arrives.
    switch MentionRule.keyAction(key, index: mentionIndex, count: rows.count) {
    case .pass: return false
    case .select(let index): mentionIndex = index
    case .choose(let index): chooseMention(rows[index])
    case .dismiss: mentionMenu?.dismiss()
    }
    return true
  }

  private func chooseMention(_ file: ProjectFile) {
    setDraft(MentionRule.insert(file, into: workspace.draft))
  }

  /// A popup's new draft, with the cursor after it and the composer focused, as Electron does.
  private func setDraft(_ text: String) {
    workspace.draft = text
    cursorRequest += 1
  }

  private var runningBar: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(
        Activity.isBackgroundOnly(workspace.view?.items ?? [])
          ? "Finishing background tasks…" : "Muse is working…")
      Text("Send a follow-up to queue or steer.").foregroundStyle(.themeSecondary)
      Spacer()
      Picker("Follow-up behavior", selection: $workspace.mode) {
        Text("Queue next").tag(SendMode.queue)
        Text("Steer now").tag(SendMode.steer)
      }
      .pickerStyle(.segmented)
      .fixedSize()
      // The stock selected segment: the theme's light accent under a white label is unreadable.
      .tint(nil)
      Button("Stop Muse", systemImage: "stop.circle.fill") { Task { await workspace.stop() } }
        .labelStyle(.iconOnly)
        .help("Stop Muse")
    }
    .font(.callout)
  }

  private var placeholder: String {
    workspace.project.isEmpty ? "Ask Muse anything…" : "Ask Muse about your project…"
  }

  private var footnote: String? {
    if workspace.view == nil, workspace.project.isEmpty { return "Select a project when you send your first message." }
    if workspace.startInWorktree, workspace.canStartInWorktree {
      return "Muse will create a separate Git worktree for this conversation."
    }
    return nil
  }

  /// A command runs while disconnected, as in Electron; a message needs the connection. Nothing
  /// sends while voice input records or transcribes: a recording never sends itself.
  private var canSend: Bool {
    guard !workspace.submitting, workspace.openingSessionId == nil, controller.voice?.isBusy != true
    else { return false }
    if ShellRule.command(in: workspace.draft) != nil { return workspace.isConnected }
    if ComposerCommand.parse(workspace.draft) != nil { return true }
    // As `Workspace.send`: a message can be attachment chips alone.
    return workspace.isConnected
      && (!workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !workspace.attachments.isEmpty)
  }

  /// Sends the draft, or runs it as a command when it parses as one, so `/word` never reaches the
  /// model as a message.
  private func submit() {
    guard canSend else { return }
    if let command = ShellRule.command(in: workspace.draft) {
      Task { await workspace.runShell(command) }
      return
    }
    if let command = ComposerCommand.parse(workspace.draft) {
      Task { if let effect = await workspace.run(command) { apply(effect) } }
    } else {
      Task { await controller.send() }
    }
  }

  /// What a command asks of the window, after `Workspace.run` has done its part.
  private func apply(_ effect: CommandEffect) {
    switch effect {
    case .renameSheet(let title):
      controller.sheets.rename(title: title)
    case .settings:
      settingsPane = .appearance
      openSettings()
    case .help:
      controller.sheets.help = true
    case .toggleVoice:
      // As Electron's toggle, which returns early while the mic button is disabled: a command runs
      // while disconnected, but voice input needs the connection.
      guard workspace.isConnected else { return }
      Task { await controller.voice?.toggle() }
    case .cancelVoice:
      controller.voice?.cancel()
    case .modelPicker:
      PickerOpener.open("model-picker")
    case .effortPicker:
      PickerOpener.open("effort-picker")
    case .sideChat:
      controller.sheets.sideChat = true
    }
  }

  private var modelSelection: Binding<String> {
    Binding(
      get: { pendingModel ?? workspace.modelId },
      set: { id in
        pendingModel = id
        Task {
          await workspace.chooseModel(id)
          // A later choice may still be saving; it clears its own.
          if pendingModel == id { pendingModel = nil }
        }
      })
  }

  private var modeSelection: Binding<String> {
    Binding(
      get: { pendingMode ?? workspace.approvalMode },
      set: { mode in
        pendingMode = mode
        Task {
          await workspace.chooseApprovalMode(mode)
          if pendingMode == mode { pendingMode = nil }
        }
      })
  }

  private var effortSelection: Binding<String> {
    Binding(
      get: { pendingEffort ?? workspace.effort },
      set: { effort in
        pendingEffort = effort
        Task {
          await workspace.chooseEffort(effort)
          if pendingEffort == effort { pendingEffort = nil }
        }
      })
  }
}
