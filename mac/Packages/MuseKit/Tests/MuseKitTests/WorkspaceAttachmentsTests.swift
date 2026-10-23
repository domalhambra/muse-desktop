import Foundation
import MuseBackend
import MuseBackendTesting
import Synchronization
import Testing
@testable import MuseKit

/// What the backend saw of a file when the request came: its path, size and modes.
private final class FileProbe: Sendable {
  struct Seen: Sendable {
    let path: String
    let size: Int
    let fileMode: Int
    let folderMode: Int
  }

  private let value = Mutex<Seen?>(nil)

  func record(_ path: String) {
    let manager = FileManager.default
    let file = try? manager.attributesOfItem(atPath: path)
    let folder = try? manager.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)
    let seen = Seen(
      path: path, size: (file?[.size] as? Int) ?? -1, fileMode: (file?[.posixPermissions] as? Int) ?? -1,
      folderMode: (folder?[.posixPermissions] as? Int) ?? -1)
    value.withLock { $0 = seen }
  }

  var seen: Seen? { value.withLock { $0 } }
}

/// The paths in an `attachments` request: one array argument.
private func paths(in args: [JSONValue]) -> [String] {
  guard case .array(let values)? = args.first else { return [] }
  return values.compactMap { value -> String? in
    if case .string(let path) = value { return path }
    return nil
  }
}

/// Answers `attachments` with one chip per path, numbered a1, a2… across calls, `open` with s1,
/// and the rest with null, unless `extra` answers. `probe` sees each attached file.
private func attachmentScript(
  probe: FileProbe? = nil,
  _ extra: @escaping @Sendable (String, [JSONValue], Int) -> [String]? = { _, _, _ in nil }
) -> @Sendable (String, [JSONValue], Int) -> [String] {
  let count = Counter()
  return { method, args, id in
    if let answer = extra(method, args, id) { return answer }
    switch method {
    case "attachments":
      let chips = paths(in: args).map { path in
        probe?.record(path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return #"{"id":"a\#(count.next())","name":"\#(name)","kind":"text","size":3}"#
      }
      return [reply(id, "[\(chips.joined(separator: ","))]")]
    case "open":
      return [reply(id, viewJSON(sessionJSON("s1")))]
    default:
      return [reply(id, "null")]
    }
  }
}

private func files(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/d/\($0)") } }

@MainActor @Test func attachingAddsChipsInOrder() async throws {
  let (workspace, backend) = await makeWorkspace(script: attachmentScript())
  await workspace.attach(files("a.txt", "shot.png"))
  #expect(workspace.attachments.map(\.id) == ["a1", "a2"])
  #expect(workspace.attachments.map(\.name) == ["a.txt", "shot.png"])
  #expect(requests(backend) == [["attachments", [["/d/a.txt", "/d/shot.png"]]]])
}

@MainActor @Test func moreThanFiveChipsAreRefusedAndTheNewIdsForgotten() async throws {
  let (workspace, backend) = await makeWorkspace(script: attachmentScript())
  await workspace.attach(files("1", "2", "3"))
  await workspace.attach(files("4", "5", "6"))
  #expect(workspace.attachments.map(\.id) == ["a1", "a2", "a3"])
  #expect(workspace.errorMessage == "You can attach up to five files per message.")
  #expect(Array(requests(backend).suffix(3)) == [
    ["remove-attachment", ["a4"]], ["remove-attachment", ["a5"]], ["remove-attachment", ["a6"]],
  ])
}

@MainActor @Test func aBackendRefusalShowsItsMessage() async throws {
  let (workspace, _) = await makeWorkspace(script: attachmentScript { method, _, id in
    method == "attachments" ? [failure(id, "big.bin must be a file smaller than 2 MB.")] : nil
  })
  await workspace.attach(files("big.bin"))
  #expect(workspace.attachments.isEmpty)
  #expect(workspace.errorMessage == "big.bin must be a file smaller than 2 MB.")
}

@MainActor @Test func removingAChipDropsItAtOnceAndTellsTheBackend() async throws {
  let (workspace, backend) = await makeWorkspace(script: attachmentScript())
  await workspace.attach(files("a.txt", "b.txt"))
  await workspace.removeAttachment("a1")
  #expect(workspace.attachments.map(\.id) == ["a2"])
  #expect(requests(backend).last == ["remove-attachment", ["a1"]])
}

@MainActor @Test func chipsAloneCanBeSentAndAreClearedOnSuccess() async throws {
  let (workspace, backend) = await makeWorkspace(script: attachmentScript())
  await workspace.open("s1")
  await workspace.attach(files("a.txt", "b.txt"))
  #expect(await workspace.send() == .sent)
  #expect(requests(backend).last == [
    "send", [["sessionId": "s1", "text": "", "attachments": ["a1", "a2"], "effort": "high", "mode": "queue"]],
  ])
  #expect(workspace.attachments.isEmpty)
  // Electron's display text: the message, then one line per chip.
  #expect(workspace.view?.items.last?.displayText == "\n[Attached: a.txt]\n[Attached: b.txt]")
  #expect(workspace.view?.items.last?.text == "")
}

@MainActor @Test func aFailedSendKeepsTheChips() async throws {
  let (workspace, _) = await makeWorkspace(script: attachmentScript { method, _, id in
    method == "send" ? [failure(id, "An attachment expired. Select it again.")] : nil
  })
  await workspace.open("s1")
  await workspace.attach(files("a.txt"))
  workspace.draft = "Look"
  #expect(await workspace.send() == .notSent)
  #expect(workspace.attachments.map(\.id) == ["a1"])
  #expect(workspace.draft == "Look")
  #expect(workspace.errorMessage == "An attachment expired. Select it again.")
}

@MainActor @Test func neitherTextNorChipsSendsNothing() async throws {
  let (workspace, backend) = await makeWorkspace(script: attachmentScript())
  await workspace.open("s1")
  workspace.draft = "  \n"
  #expect(await workspace.send() == .notSent)
  #expect(!backend.messages.contains { $0["method"] == "send" })
}

@MainActor @Test func aPastedImageIsAPrivateFileUntilItsMessageIsSent() async throws {
  let probe = FileProbe()
  let (workspace, _) = await makeWorkspace(script: attachmentScript(probe: probe))
  await workspace.open("s1")
  await workspace.attachPasted(Data([0x89, 0x50, 0x4E, 0x47]), type: "public.png")
  let seen = try #require(probe.seen)
  #expect(seen.path.hasSuffix("/Pasted image.png"))
  #expect(seen.size == 4)
  #expect(seen.fileMode == 0o600)
  #expect(seen.folderMode == 0o700)
  #expect(workspace.attachments.map(\.name) == ["Pasted image.png"])
  #expect(FileManager.default.fileExists(atPath: seen.path))
  #expect(await workspace.send() == .sent)
  #expect(!FileManager.default.fileExists(atPath: seen.path))
  #expect(!FileManager.default.fileExists(atPath: (seen.path as NSString).deletingLastPathComponent))
}

@MainActor @Test func aRemovedPastedImageIsDeleted() async throws {
  let probe = FileProbe()
  let (workspace, _) = await makeWorkspace(script: attachmentScript(probe: probe))
  await workspace.attachPasted(Data([1, 2, 3]), type: "public.jpeg")
  let seen = try #require(probe.seen)
  #expect(seen.path.hasSuffix("/Pasted image.jpg"))
  await workspace.removeAttachment("a1")
  #expect(!FileManager.default.fileExists(atPath: seen.path))
}

@MainActor @Test func aPastedImagePastTheLimitIsDeleted() async throws {
  let probe = FileProbe()
  let (workspace, _) = await makeWorkspace(script: attachmentScript(probe: probe))
  await workspace.attach(files("1", "2", "3", "4", "5"))
  await workspace.attachPasted(Data([1]), type: "public.png")
  let seen = try #require(probe.seen)
  #expect(seen.path.hasSuffix("/Pasted image.png"))
  #expect(workspace.attachments.count == 5)
  #expect(workspace.errorMessage == "You can attach up to five files per message.")
  #expect(!FileManager.default.fileExists(atPath: seen.path))
}

@MainActor @Test func anImageTypeTheBackendCannotSendIsRefused() async throws {
  let (workspace, backend) = await makeWorkspace(script: attachmentScript())
  await workspace.attachPasted(Data([1]), type: "public.tiff")
  #expect(workspace.errorMessage == "Paste a PNG, JPEG, WebP or GIF image.")
  #expect(backend.messages.isEmpty)
}

@MainActor @Test func pastedTypesMapToTheExtensionsTheBackendReads() {
  #expect(Workspace.pastedImageExtension("public.png") == "png")
  #expect(Workspace.pastedImageExtension("public.jpeg") == "jpg")
  #expect(Workspace.pastedImageExtension("com.compuserve.gif") == "gif")
  #expect(Workspace.pastedImageExtension("org.webmproject.webp") == "webp")
  #expect(Workspace.pastedImageExtension("public.tiff") == nil)
  #expect(Workspace.pastedImageExtension("not a type") == nil)
}

@MainActor @Test func aDropAttachesFilesInsertsMentionsAndShowsTheFolderError() async throws {
  let base = FileManager.default.temporaryDirectory
    .appending(path: "mmac-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: base) }
  let project = base.appending(path: "project", directoryHint: .isDirectory)
  let src = project.appending(path: "src", directoryHint: .isDirectory)
  let outside = base.appending(path: "outside", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  let file = project.appending(path: "notes.txt")
  try Data("hi".utf8).write(to: file)
  let (workspace, backend) = await makeWorkspace(
    preferences: Preferences(recentProjects: [project.path]), script: attachmentScript())
  workspace.draft = "Look at"
  let focus = workspace.composerFocusRequest
  await workspace.drop([file, src])
  #expect(workspace.draft == "Look at @src/")
  #expect(workspace.composerFocusRequest == focus + 1)
  #expect(workspace.attachments.map(\.name) == ["notes.txt"])
  #expect(requests(backend).last == ["attachments", [[.string(file.path)]]])
  #expect(workspace.errorMessage == nil)
  await workspace.drop([outside])
  #expect(workspace.errorMessage == "Drop files, or a folder inside this project.")
  #expect(workspace.draft == "Look at @src/")
}

@MainActor @Test func aFailedRemovalShowsItsMessage() async throws {
  let (workspace, _) = await makeWorkspace(script: attachmentScript { method, _, id in
    method == "remove-attachment" ? [failure(id, "Muse is not running.")] : nil
  })
  await workspace.attach(files("a.txt"))
  await workspace.removeAttachment("a1")
  #expect(workspace.errorMessage == "Muse is not running.")
  #expect(workspace.attachments.isEmpty)
}

@MainActor @Test func aChipInASendInFlightCannotBeRemovedAndOneAddedMeanwhileStays() async throws {
  let (workspace, backend) = await makeWorkspace(script: attachmentScript { method, _, _ in
    method == "send" ? [] : nil
  })
  await workspace.open("s1")
  await workspace.attach(files("a.txt"))
  let sending = Task { await workspace.send() }
  try await eventually { backend.messages.contains { $0["method"] == "send" } }
  #expect(workspace.isSending("a1"))
  await workspace.removeAttachment("a1")
  #expect(workspace.attachments.map(\.id) == ["a1"])
  #expect(!backend.messages.contains { $0["method"] == "remove-attachment" })
  // A chip added during the send is not part of it: it can go, and it stays if left.
  await workspace.attach(files("b.txt"))
  #expect(!workspace.isSending("a2"))
  let sendIds = backend.messages.compactMap { message -> Int? in
    guard message["method"] == "send", case .number(let id)? = message["id"] else { return nil }
    return Int(id)
  }
  let sendId = try #require(sendIds.first)
  backend.push(reply(sendId, "null"))
  #expect(await sending.value == .sent)
  #expect(workspace.attachments.map(\.id) == ["a2"])
  #expect(workspace.sendingAttachmentIds.isEmpty)
}

@MainActor @Test func aFolderErrorSurvivesALaterAttachError() async throws {
  let base = FileManager.default.temporaryDirectory
    .appending(path: "mmac-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: base) }
  let project = base.appending(path: "project", directoryHint: .isDirectory)
  let outside = base.appending(path: "outside", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  let file = project.appending(path: "big.bin")
  try Data("x".utf8).write(to: file)
  let (workspace, _) = await makeWorkspace(
    preferences: Preferences(recentProjects: [project.path]),
    script: attachmentScript { method, _, id in
      method == "attachments" ? [failure(id, "big.bin must be a file smaller than 2 MB.")] : nil
    })
  await workspace.drop([file, outside])
  #expect(workspace.errorMessage == "big.bin must be a file smaller than 2 MB.\nDrop files, or a folder inside this project.")
}

@MainActor @Test func aDropDoesNotJoinAnEarlierError() async throws {
  let (workspace, _) = await makeWorkspace(script: attachmentScript())
  workspace.errorMessage = "An older error."
  await workspace.drop([])
  #expect(workspace.errorMessage == "An older error.")
  await workspace.drop([FileManager.default.temporaryDirectory])
  #expect(workspace.errorMessage == DropPlan.folderError)
}

@MainActor @Test func sendEmptinessFollowsJavaScriptsTrim() async throws {
  let (workspace, backend) = await makeWorkspace(script: attachmentScript())
  await workspace.open("s1")
  // U+FEFF is whitespace to JavaScript's trim, not to Swift's: the backend sees an empty message.
  workspace.draft = "\u{FEFF}"
  #expect(await workspace.send() == .notSent)
  #expect(!backend.messages.contains { $0["method"] == "send" })
  // U+0085 is whitespace to Swift, not to JavaScript: the backend sends it.
  workspace.draft = "\u{0085}"
  #expect(await workspace.send() == .sent)
  #expect(backend.messages.contains { $0["method"] == "send" })
}

@MainActor @Test func chipsBelongToTheComposerAndOutliveAConversationSwitch() async throws {
  let (workspace, _) = await makeWorkspace(
    script: attachmentScript { method, args, id in
      guard method == "open", case .string(let sessionId)? = args.first else { return nil }
      return [reply(id, viewJSON(sessionJSON(sessionId)))]
    })
  await workspace.attach(files("a.txt"))
  #expect(workspace.attachments.map(\.name) == ["a.txt"])
  await workspace.open("s1")
  #expect(workspace.attachments.map(\.name) == ["a.txt"])
  await workspace.open("s2")
  #expect(workspace.attachments.map(\.name) == ["a.txt"])
  workspace.startNew()
  #expect(workspace.attachments.map(\.name) == ["a.txt"])
}
