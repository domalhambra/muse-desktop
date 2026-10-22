import MuseBackend
import MuseKit
import SwiftUI

/// The composer, as Electron's `Composer.tsx`, without attachments, voice and slash commands (M4).
struct ComposerView: View {
  let controller: AppController
  @Bindable var workspace: Workspace
  /// The text area's height, which it measures itself.
  @State private var inputHeight: CGFloat = 17
  /// A choice still being saved. The picker shows it until the Workspace answers, then shows the
  /// real value again, so a failed change does not leave the popup showing it.
  @State private var pendingModel: String?
  @State private var pendingEffort: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if workspace.isRunning { runningBar }
      ComposerTextView(
        text: $workspace.draft, height: $inputHeight, placeholder: placeholder,
        isEnabled: workspace.openingSessionId == nil, focusRequest: workspace.composerFocusRequest,
        onSubmit: submit
      )
      .frame(height: inputHeight)
      .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      HStack(spacing: 10) {
        Picker("Model", selection: modelSelection) {
          if !workspace.models.contains(where: { $0.modelId == workspace.modelId }) {
            Text(workspace.modelId.isEmpty ? "CLI default" : workspace.modelId).tag(workspace.modelId)
          }
          ForEach(workspace.models) { model in
            Text(model.displayLabel.isEmpty ? model.modelId : model.displayLabel).tag(model.modelId)
          }
        }
        .fixedSize()
        .disabled(workspace.submitting || workspace.models.isEmpty)
        .accessibilityIdentifier("model-picker")
        Picker("Reasoning effort", selection: effortSelection) {
          ForEach(ReasoningEffort.allCases) { effort in Text(effort.label).tag(effort.rawValue) }
          // A newer CLI's effort that this list does not know still shows.
          if ReasoningEffort(rawValue: workspace.effort) == nil {
            Text(workspace.effort).tag(workspace.effort)
          }
        }
        .fixedSize()
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
        Text("↵ Send · ⇧ ↵ New line").font(.caption).foregroundStyle(.tertiary)
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
        .help(workspace.isRunning ? "Send follow-up" : "Send message")
      }
      // On its own line, so a long note does not squeeze the row.
      if let footnote {
        Text(footnote)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("composer-footnote")
      }
    }
    .padding(12)
  }

  private var runningBar: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(
        Activity.isBackgroundOnly(workspace.view?.items ?? [])
          ? "Finishing background tasks…" : "Muse is working…")
      Text("Send a follow-up to queue or steer.").foregroundStyle(.secondary)
      Spacer()
      Picker("Follow-up behavior", selection: $workspace.mode) {
        Text("Queue next").tag(SendMode.queue)
        Text("Steer now").tag(SendMode.steer)
      }
      .pickerStyle(.segmented)
      .fixedSize()
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

  private var canSend: Bool {
    !workspace.submitting && workspace.isConnected && workspace.openingSessionId == nil
      && !workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submit() {
    guard canSend else { return }
    Task { await controller.send() }
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
