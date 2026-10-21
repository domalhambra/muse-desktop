import MuseBackend
import SwiftUI

struct ContentView: View {
  @Bindable var model: AppModel

  var body: some View {
    switch model.phase {
    case .starting:
      ProgressView("Starting the Muse backend…")
    case .stopped(let message):
      ContentUnavailableView {
        Label("The Muse backend stopped", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("Restart") { Task { await model.start() } }
      }
    case .running:
      conversations
    }
  }

  private var conversations: some View {
    NavigationSplitView {
      List(model.sessions, selection: selection) { session in
        Text(session.name ?? session.title ?? session.firstUserPrompt ?? "Untitled conversation")
          .lineLimit(1)
      }
      .safeAreaInset(edge: .bottom) {
        Text(statusLine).font(.caption).foregroundStyle(.secondary).padding(8)
      }
      .toolbar {
        Button("New conversation", systemImage: "plus") { Task { await model.newConversation() } }
      }
    } detail: {
      if let view = model.selected {
        TranscriptView(view: view, draft: $model.draft) { Task { await model.send() } }
      } else {
        ContentUnavailableView(
          "No conversation", systemImage: "bubble.left.and.bubble.right",
          description: Text("Choose one, or start a new conversation."))
      }
    }
    .alert("Muse", isPresented: errorShown) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private var selection: Binding<String?> {
    Binding(
      get: { model.selected?.session.sessionId },
      set: { sessionId in
        if let sessionId { Task { await model.open(sessionId) } }
      })
  }

  private var errorShown: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  private var statusLine: String {
    guard let status = model.status else { return "Connecting to Muse…" }
    if status.state == "ready" { return "Connected to Muse Code \(status.version ?? "")" }
    return status.message ?? status.state
  }
}

struct TranscriptView: View {
  let view: SessionView
  @Binding var draft: String
  let send: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(view.items.filter { ["userMessage", "agentMessage"].contains($0.kind) }) { item in
            VStack(alignment: .leading, spacing: 4) {
              Text(item.kind == "userMessage" ? "You" : "Muse")
                .font(.caption).foregroundStyle(.secondary)
              Text(item.displayText ?? item.text ?? "").textSelection(.enabled)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      Divider()
      HStack {
        TextField("Message Muse", text: $draft).onSubmit(send)
        Button("Send", action: send)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding()
    }
    .navigationTitle(view.session.name ?? view.session.title ?? "Conversation")
  }
}
