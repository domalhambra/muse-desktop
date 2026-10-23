import AppKit
import MuseKit
import SwiftUI

/// The mic button, as Electron's `VoiceInput.tsx`, with its status pill above it.
struct VoiceButton: View {
  let voice: VoiceSession
  let workspace: Workspace

  /// Electron's recording color.
  static let recordingColor = Color(hex: "#e85d6f")

  var body: some View {
    Button {
      Task { await voice.toggle() }
    } label: {
      icon
    }
    .buttonStyle(.borderless)
    .disabled(disabled)
    .accessibilityLabel(voice.buttonLabel)
    .accessibilityAddTraits(voice.phase == .recording ? .isSelected : [])
    .help(voice.buttonLabel)
    .accessibilityIdentifier("voice-button")
    .overlay(alignment: .topLeading) {
      if voice.isBusy {
        VoiceStatusPill(voice: voice)
          .fixedSize()
          // Above the button, 10 points clear, as Electron's pill.
          .alignmentGuide(.top) { $0[.bottom] + 10 }
      }
    }
  }

  /// As Electron: off while sending or disconnected, and while the microphone opens or Muse
  /// transcribes. A recording can always be stopped.
  private var disabled: Bool {
    switch voice.phase {
    case .idle: workspace.submitting || !workspace.isConnected
    case .recording: false
    case .permission, .transcribing: true
    }
  }

  @ViewBuilder private var icon: some View {
    switch voice.phase {
    case .idle: Image(systemName: "mic")
    case .recording: Image(systemName: "stop.fill").foregroundStyle(Self.recordingColor)
    case .permission, .transcribing: ProgressView().controlSize(.small)
    }
  }
}

/// The status above the mic button in every busy phase, with its cancel button.
struct VoiceStatusPill: View {
  let voice: VoiceSession
  @Environment(\.appearance) private var appearance

  var body: some View {
    HStack(spacing: 8) {
      if voice.phase == .recording { VoiceLevels(levels: voice.levels) }
      Text(voice.statusText ?? "").font(.callout).monospacedDigit()
      Button {
        voice.cancel()
      } label: {
        Image(systemName: "xmark").font(.caption2.weight(.semibold))
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(VoiceSession.cancelLabel)
      .help(VoiceSession.cancelLabel)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(appearance.colors.dialog, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityIdentifier("voice-status")
  }
}

/// Electron's five bars: 2.5 by 14 points, each scaled by its height.
struct VoiceLevels: View {
  let levels: [Double]
  @Environment(\.appearance) private var appearance

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<5, id: \.self) { index in
        Capsule()
          .fill(VoiceButton.recordingColor)
          .frame(width: 2.5, height: 14)
          .scaleEffect(x: 1, y: index < levels.count ? levels[index] : VoiceMeter.floor)
      }
    }
    .animation(appearance.reduceMotion ? nil : .easeOut(duration: 0.1), value: levels)
    .accessibilityHidden(true)
  }
}

/// Escape cancels voice input anywhere in the main window, outside a sheet. Minimising or
/// closing the window, or hiding mMac, cancels too, as Electron cancels when its page is hidden.
struct VoiceCancellation: ViewModifier {
  let voice: VoiceSession?
  /// The Escape monitor, installed only while voice is busy.
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onChange(of: voice?.isBusy ?? false) { _, busy in
        if busy { addMonitor() } else { removeMonitor() }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { note in
        if let window = note.object as? NSWindow, MMacApp.isMainWindow(window) { voice?.cancel() }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
        if let window = note.object as? NSWindow, MMacApp.isMainWindow(window) { voice?.cancel() }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
        voice?.cancel()
      }
      .onDisappear { removeMonitor() }
  }

  private func addMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [voice] event in
      guard event.keyCode == 53, !event.isARepeat else { return event }
      let eventWindow = event.window
      // Local monitors run on the main thread. `assumeIsolated` must return a Sendable value and
      // NSEvent is not, so it returns a Bool, as SheetAlert's Escape monitor does.
      let handled = MainActor.assumeIsolated { () -> Bool in
        guard let voice, voice.isBusy, let eventWindow, MMacApp.isMainWindow(eventWindow) else { return false }
        voice.cancel()
        return true
      }
      return handled ? nil : event
    }
  }

  private func removeMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}
