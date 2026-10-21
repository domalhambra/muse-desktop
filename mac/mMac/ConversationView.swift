import MuseKit
import SwiftUI

struct ConversationView: View {
  let controller: AppController
  @Bindable var workspace: Workspace

  var body: some View {
    Text(workspace.view.map { SessionTitle.of($0.session) } ?? "No conversation")
  }
}
