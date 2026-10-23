import MuseBackend
import MuseKit
import SwiftUI

/// A side question beside the main conversation, as Desktop's side chat (⌘;). Muse seeds the side
/// session from the conversation; nothing typed here joins it.
struct SideChatSheet: View {
  let controller: AppController
  let workspace: Workspace
  let close: () -> Void
  @State private var question = ""
  @State private var sending = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Side chat").font(.headline)
          Text("Nothing here joins the main conversation.").font(.caption).foregroundStyle(.themeSecondary)
        }
        Spacer()
        Button("Close") {
          workspace.closeSideChat()
          close()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("side-chat-close")
      }
      .padding(16)
      Divider()
      Group {
        if let side = workspace.sideView {
          TranscriptView(controller: controller, workspace: workspace, view: side).id(side.session.sessionId)
        } else {
          ProgressView("Opening side chat…")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      HStack(spacing: 8) {
        TextField("Ask a side question…", text: $question)
          .textFieldStyle(.roundedBorder)
          .onSubmit(send)
          .accessibilityIdentifier("side-chat-field")
        Button("Send", action: send)
          .buttonStyle(.primary)
          .disabled(sending || workspace.sideView == nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("side-chat-send")
      }
      .padding(12)
    }
    .frame(width: 640, height: 520)
    .task { if workspace.sideView == nil { await workspace.openSideChat() } }
    .accessibilityIdentifier("side-chat-sheet")
  }

  private func send() {
    let text = question
    guard !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    sending = true
    Task {
      await workspace.sendToSide(text)
      if workspace.errorMessage == nil { question = "" }
      sending = false
    }
  }
}

/// A subagent's session, read-only, from the Agents tab.
struct ChildSessionSheet: View {
  let controller: AppController
  let workspace: Workspace
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(workspace.childView.map { SessionTitle.of($0.session) } ?? "Subagent").font(.headline)
        Spacer()
        Button("Close") {
          workspace.closeChild()
          close()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("child-close")
      }
      .padding(16)
      Divider()
      Group {
        if let child = workspace.childView {
          TranscriptView(controller: controller, workspace: workspace, view: child).id(child.session.sessionId)
        } else {
          ProgressView("Opening…")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 640, height: 520)
    .accessibilityIdentifier("child-sheet")
  }
}
