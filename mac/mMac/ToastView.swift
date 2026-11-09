import MuseKit
import SwiftUI

/// The success toast, as Electron's `showSuccess`: the Workspace's notice, for 4 seconds. Errors
/// keep the window's alert, which stays until dismissed.
struct ToastView: View {
  let workspace: Workspace
  @Environment(\.appearance) private var appearance

  /// How long a notice shows, as Electron's toast.
  static let duration: Duration = .seconds(4)

  var body: some View {
    ZStack {
      if let notice = workspace.notice {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color(hex: appearance.palette.green))
            .accessibilityHidden(true)
          Text(notice)
          Button {
            workspace.notice = nil
          } label: {
            Image(systemName: "xmark").font(.caption2.weight(.semibold))
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Dismiss notification")
          .help("Dismiss notification")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(appearance.colors.dialog, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toast")
        .transition(.opacity)
        // Every `showNotice` bumps `noticeCount`, so a new notice restarts the 4 seconds, even
        // with the same text. One a newer notice replaced is not cleared early.
        .task(id: workspace.noticeCount) {
          let count = workspace.noticeCount
          AccessibilityNotification.Announcement(notice).post()
          try? await Task.sleep(for: Self.duration)
          guard !Task.isCancelled, workspace.noticeCount == count else { return }
          workspace.notice = nil
        }
      }
    }
    .animation(appearance.reduceMotion ? nil : .easeOut(duration: 0.2), value: workspace.notice)
  }
}
