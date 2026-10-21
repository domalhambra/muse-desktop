import MuseKit
import SwiftUI

struct SidebarView: View {
  let controller: AppController
  @Bindable var workspace: Workspace

  var body: some View {
    List(workspace.sessions) { session in Text(SessionTitle.of(session)) }
  }
}
