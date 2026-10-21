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

  static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if workspace.isRunning { runningBar }
      ComposerTextView(
        text: $workspace.draft, height: $inputHeight, placeholder: placeholder,
        isEnabled: workspace.openingSessionId == nil, onSubmit: submit
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
          ForEach(Self.efforts, id: \.self) { effort in Text(Self.label(effort)).tag(effort) }
        }
        .fixedSize()
        Spacer()
        if let footnote {
          Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
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

  static func label(_ effort: String) -> String {
    effort == "xhigh" ? "Extra high" : effort.prefix(1).uppercased() + effort.dropFirst()
  }

  private var placeholder: String {
    workspace.project.isEmpty ? "Ask Muse anything…" : "Ask Muse about your project…"
  }

  private var footnote: String? {
    workspace.view == nil && workspace.project.isEmpty
      ? "Select a project when you send your first message." : nil
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
