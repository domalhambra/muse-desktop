/// The reasoning efforts Muse Code accepts, in Electron's order (`efforts` in
/// src/renderer/src/components/Composer.tsx). Preferences keep the raw string, so a newer CLI's
/// effort still decodes; the composer lists these.
public enum ReasoningEffort: String, CaseIterable, Sendable, Identifiable {
  case none, minimal, low, medium, high, xhigh, max, ultra

  public var id: String { rawValue }

  /// "Extra high" for `xhigh`, otherwise the name with a capital first letter.
  public var label: String {
    self == .xhigh ? "Extra high" : rawValue.prefix(1).uppercased() + rawValue.dropFirst()
  }
}
