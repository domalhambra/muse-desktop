import Foundation
import MuseBackend
import UniformTypeIdentifiers

// The composer's attachment chips, as Electron's Composer.tsx keeps them: one list for the
// window, beside the draft and not per conversation. The chip ids belong to one backend, so the
// Workspace for a restarted backend starts with none.
extension Workspace {
  public static let maxAttachments = 5
  public static let tooManyAttachments = "You can attach up to five files per message."
  public static let unsupportedPaste = "Paste a PNG, JPEG, WebP or GIF image."

  /// Attaches files chosen in the panel or dropped on the composer. The backend checks each file.
  public func attach(_ urls: [URL]) async {
    _ = await attachReturningNew(urls)
  }

  /// Removes a chip at once, then tells the backend, as Electron does. A pasted image's file goes too.
  public func removeAttachment(_ id: String) async {
    // A chip in a send in flight stays: the backend is reading it.
    guard !sendingAttachmentIds.contains(id) else { return }
    attachments.removeAll { $0.id == id }
    pastedFiles.forget([id])
    await run { try await self.client.removeAttachment(id) }
  }

  /// Attaches a pasted image. `type` is the pasteboard's type identifier, such as `public.png`.
  /// The data goes to a private temp file, so it crosses to the backend as a path.
  public func attachPasted(_ data: Data, type: String) async {
    guard let ext = Self.pastedImageExtension(type) else {
      errorMessage = Self.unsupportedPaste
      return
    }
    let file: URL
    do {
      file = try pastedFiles.write(data, named: "Pasted image.\(ext)")
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    guard let added = await attachReturningNew([file]), let chip = added.first else {
      pastedFiles.discard(file)
      return
    }
    pastedFiles.remember(chip.id, file: file)
  }

  /// Whether the composer takes typing, popup choices and drops. Not while a conversation opens:
  /// the draft's key is about to change, so text added now could land in the wrong draft.
  public var composerIsEditable: Bool { openingSessionId == nil }

  /// A drop on the composer: files become chips, a folder inside the project becomes a mention at
  /// the end of the draft, and a folder outside it shows the folder error.
  public func drop(_ urls: [URL]) async {
    guard composerIsEditable else { return }
    let plan = DropPlan.classify(urls, project: project)
    if !plan.mentions.isEmpty {
      draft = plan.appendingMentions(to: draft)
      composerFocusRequest += 1
    }
    // An earlier error is set aside, so only this drop's own errors are shown, one per line.
    let earlier = errorMessage
    errorMessage = nil
    if !plan.files.isEmpty { await attach(plan.files) }
    let own = [errorMessage, plan.error].compactMap { $0 }
    errorMessage = own.isEmpty ? earlier : own.joined(separator: "\n")
  }

  /// The extension the backend reads as an image (`png`, `jpg`, `gif`, `webp`), or nil.
  static func pastedImageExtension(_ type: String) -> String? {
    guard let type = UTType(type) else { return nil }
    if type.conforms(to: .png) { return "png" }
    if type.conforms(to: .jpeg) { return "jpg" }
    if type.conforms(to: .gif) { return "gif" }
    if type.conforms(to: .webP) { return "webp" }
    return nil
  }

  /// Electron's `attach`: register first, then refuse the whole batch, and forget its ids, when
  /// the chips would pass five. Returns the new chips, or nil after an error.
  private func attachReturningNew(_ urls: [URL]) async -> [Attachment]? {
    guard !urls.isEmpty else { return [] }
    do {
      let added = try await client.attachments(urls)
      if attachments.count + added.count > Self.maxAttachments {
        for chip in added { try? await client.removeAttachment(chip.id) }
        throw WorkspaceError(Self.tooManyAttachments)
      }
      attachments += added
      return added
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}

/// Pasted images on disk. Each paste gets its own folder in one private temp folder, so its chip
/// reads "Pasted image.png". A file goes once its chip is sent or removed, and the whole folder
/// goes with the Workspace that owns this store.
final class PastedFiles {
  private var root: URL?
  /// Chip id → the folder that holds its file.
  private var folders: [String: URL] = [:]

  deinit {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  /// Writes one pasted image, mode 0600, in a new folder, mode 0700.
  func write(_ data: Data, named name: String) throws -> URL {
    let root = try self.root ?? PrivateTemp.makeFolder("pasted")
    self.root = root
    let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return try PrivateTemp.write(data, named: name, in: folder)
  }

  func remember(_ id: String, file: URL) {
    folders[id] = file.deletingLastPathComponent()
  }

  /// Deletes the files of these chips, for those that were pasted.
  func forget(_ ids: some Sequence<String>) {
    for id in ids {
      if let folder = folders.removeValue(forKey: id) { try? FileManager.default.removeItem(at: folder) }
    }
  }

  /// Deletes a pasted file that never became a chip.
  func discard(_ file: URL) {
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
  }
}

/// Private temp folders (0700) and files (0600) in the user's temp folder, named for mMac, for
/// data that crosses to the backend as a path: pasted images and voice clips. The spec keeps large
/// data off the JSON wire.
enum PrivateTemp {
  static func makeFolder(_ purpose: String, in base: URL = FileManager.default.temporaryDirectory) throws -> URL {
    let folder = base
      .appending(path: "mMac-\(purpose)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return folder
  }

  static func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
    let file = folder.appending(path: name, directoryHint: .notDirectory)
    guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw WorkspaceError("mMac could not write a temporary file.") }
    return file
  }
}
