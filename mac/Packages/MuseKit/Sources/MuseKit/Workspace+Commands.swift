import Foundation
import MuseBackend
import Observation

/// What the app does after a composer command, for the parts only a view can do. Backend calls
/// happen in `Workspace.run(_:)`.
public enum CommandEffect: Equatable, Sendable {
  /// `/rename` with no name: open the Rename sheet with this title in its field.
  case renameSheet(title: String)
  /// `/settings`: open Settings on Appearance.
  case settings
  /// `/help`: open the Help sheet. mMac has no docs page.
  case help
  /// `/voice`: start or stop voice input.
  case toggleVoice
  /// `/voice cancel`: discard voice input.
  case cancelVoice
  /// `/model` with no id: open the Model picker.
  case modelPicker
  /// `/effort` with no level: open the Reasoning effort picker.
  case effortPicker
  /// `/btw`: open the side chat sheet.
  case sideChat
}

// Running a composer command, as Electron's `submit` in src/renderer/src/App.tsx does.
extension Workspace {
  public static let needsConversation = "Open a conversation before using this command."
  public static let commandWithAttachments =
    "Send attachments with a message, or remove them before using a command."

  /// Runs a parsed command. An error shows in `errorMessage` and keeps the draft; success clears
  /// the draft the command was typed in. Returns what the app must do next, if anything.
  @discardableResult
  public func run(_ command: ParsedCommand) async -> CommandEffect? {
    guard !submitting else { return nil }
    submitting = true
    defer { submitting = false }
    // Taken now: /new and /clear change the key.
    let key = draftKey
    do {
      let effect = try await perform(command)
      drafts[key] = nil
      return effect
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func perform(_ command: ParsedCommand) async throws -> CommandEffect? {
    guard let known = ComposerCommand(rawValue: command.name) else {
      throw WorkspaceError(
        "/\(command.name) is not handled by Desktop. Use /help, or open Muse Code in the project inspector for CLI commands."
      )
    }
    guard attachments.isEmpty else { throw WorkspaceError(Self.commandWithAttachments) }
    let argument = command.argument
    switch known {
    case .clear, .new:
      startNew()
      return nil
    case .help:
      return .help
    case .btw:
      guard view != nil else { throw WorkspaceError(Self.needsConversation) }
      return .sideChat
    case .settings:
      return .settings
    case .voice:
      // Matched exactly, as Electron does.
      switch argument {
      case "": return .toggleVoice
      case "cancel": return .cancelVoice
      case "status":
        showNotice("Use ⌥V to start or stop recording. Muse Code transcribes speech into your draft.")
        return nil
      default:
        throw WorkspaceError("Use /voice to record, /voice cancel to discard, or /voice status for help.")
      }
    case .model:
      guard !argument.isEmpty else { return .modelPicker }
      // The id is case-sensitive.
      guard models.contains(where: { $0.modelId == argument }) else {
        throw WorkspaceError("Choose one of the models available in the Model menu.")
      }
      guard let sessionId = view?.session.sessionId else {
        modelId = argument
        return nil
      }
      let sequence = openSequence
      try await client.setModel(sessionId: sessionId, modelId: argument)
      // As `chooseModel`: not over a conversation the person opened meanwhile.
      if sequence == openSequence, view?.session.sessionId == sessionId { modelId = argument }
      return nil
    case .effort:
      guard !argument.isEmpty else { return .effortPicker }
      guard let effort = ReasoningEffort(rawValue: argument.lowercased()) else {
        throw WorkspaceError("Choose none, minimal, low, medium, high, xhigh, max, or ultra.")
      }
      preferences = try await client.preferences(PreferencesPatch(reasoningEffort: effort.rawValue))
      return nil
    case .compact:
      guard let session = view?.session else { throw WorkspaceError(Self.needsConversation) }
      let result = try await client.compact(session.sessionId)
      showNotice(
        result.status == "noop"
          ? "There is no conversation history to compact yet." : "Muse is compacting this conversation.")
      return nil
    case .stop:
      guard let session = view?.session else { throw WorkspaceError(Self.needsConversation) }
      try await client.cancel(session.sessionId)
      return nil
    case .rename:
      guard let session = view?.session else { throw WorkspaceError(Self.needsConversation) }
      guard argument.isEmpty else {
        // The backend trims and refuses a name over 200 characters.
        try await client.rename(sessionId: session.sessionId, name: argument)
        return nil
      }
      return .renameSheet(title: SessionTitle.of(session))
    }
  }
}

/// The `@` menu's rows. It lists one folder through `files` when the project, the folder, or
/// whether a mention is open changes, not on every typed letter, as Electron's effect does.
/// Escape empties it until the folder changes. A failed listing shows no rows and no error.
@MainActor @Observable
public final class MentionMenu {
  private struct Folder: Equatable {
    let project: String
    let directory: String
  }

  /// The listed folder's entries, before the filter.
  public private(set) var files: [ProjectFile] = []
  @ObservationIgnored private var folder: Folder?
  @ObservationIgnored private var sequence = 0
  private let workspace: Workspace

  public init(workspace: Workspace) {
    self.workspace = workspace
  }

  /// The rows to show for `draft`: at most 12, filtered by the mention's filter.
  public func rows(for draft: String) -> [ProjectFile] {
    guard !workspace.project.isEmpty, let mention = MentionRule.match(draft) else { return [] }
    return MentionRule.rows(files, filter: mention.filter)
  }

  /// Call when the draft changes. Lists the mention's folder when it differs from the one listed.
  /// The app keys its task on the folder, so typing the filter does not cancel a listing.
  public func update(draft: String) async {
    let project = workspace.project
    let next = project.isEmpty ? nil : MentionRule.match(draft).map { Folder(project: project, directory: $0.directory) }
    guard next != folder else { return }
    folder = next
    sequence += 1
    // Not the old folder's entries: their paths belong to another folder.
    files = []
    guard let next else { return }
    let current = sequence
    let entries = (try? await workspace.client.files(project: next.project, directory: next.directory)) ?? []
    guard current == sequence else { return }
    // A cancelled listing is not an empty folder: list it again on the next call.
    if Task.isCancelled {
      folder = nil
      return
    }
    files = entries
  }

  /// Escape: no rows until the folder changes or the mention ends.
  public func dismiss() {
    files = []
  }
}
