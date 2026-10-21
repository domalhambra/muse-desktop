import MuseKit
import SwiftUI

struct ConversationView: View {
  let controller: AppController
  @Bindable var workspace: Workspace

  var body: some View {
    if let view = workspace.view {
      TranscriptView(workspace: workspace, view: view).id(view.session.sessionId)
    } else {
      ContentUnavailableView(
        "No conversation", systemImage: "bubble.left.and.bubble.right",
        description: Text("Choose one, or start a new conversation."))
    }
  }
}
