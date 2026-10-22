import Foundation
import Testing
import Markdown
@testable import MuseKit

private func plain(_ text: AttributedString) -> String { String(text.characters) }

private func intent(of word: String, in text: AttributedString) -> InlinePresentationIntent? {
  guard let range = text.range(of: word) else { return nil }
  return text[range].runs.first?.inlinePresentationIntent
}

@Test func headingsAndInlineStyles() {
  let blocks = MarkdownBlock.parse("# Title\n\nSome **bold**, *italic*, `code` and ~~gone~~ text.")
  guard blocks.count == 2, case .heading(let level, let title) = blocks[0],
    case .paragraph(let body) = blocks[1]
  else {
    Issue.record("Unexpected blocks: \(blocks)")
    return
  }
  #expect(level == 1)
  #expect(plain(title) == "Title")
  #expect(plain(body) == "Some bold, italic, code and gone text.")
  #expect(intent(of: "bold", in: body)?.contains(.stronglyEmphasized) == true)
  #expect(intent(of: "italic", in: body)?.contains(.emphasized) == true)
  #expect(intent(of: "code", in: body)?.contains(.code) == true)
  #expect(intent(of: "gone", in: body)?.contains(.strikethrough) == true)
  // react-markdown keeps quotes, dashes and dots as typed: no smart punctuation.
  let typed = "\"quoted\" it's -- and ... --flag"
  #expect(MarkdownBlock.parse(typed) == [.paragraph(AttributedString(typed))])
}

@Test func onlyWebLinksStayLinks() {
  guard case .paragraph(let text) = MarkdownBlock.parse("[site](https://example.com) and [bad](javascript:alert(1))").first
  else {
    Issue.record("Expected a paragraph")
    return
  }
  #expect(text[text.range(of: "site")!].runs.first?.link == URL(string: "https://example.com"))
  #expect(text[text.range(of: "bad")!].runs.first?.link == nil)
}

@Test func codeBlocksKeepTheirLanguageAndDropTheLastNewline() {
  #expect(MarkdownBlock.parse("```swift\nlet x = 1\n```") == [.code(language: "swift", code: "let x = 1")])
  #expect(MarkdownBlock.parse("```\nplain\n```") == [.code(language: nil, code: "plain")])
  // Only the info string's first word is the language, as remark's `lang`.
  #expect(MarkdownBlock.parse("```swift title=x\nlet x = 1\n```") == [.code(language: "swift", code: "let x = 1")])
}

@Test func theEchoProvidersReplyParses() {
  let blocks = MarkdownBlock.parse("echo: # Hi\n```swift\nlet x = 1\n```")
  guard blocks.count == 2, case .paragraph(let text) = blocks[0] else {
    Issue.record("Unexpected blocks: \(blocks)")
    return
  }
  #expect(plain(text) == "echo: # Hi")
  #expect(blocks[1] == .code(language: "swift", code: "let x = 1"))
}

@Test func listsKeepTheirStartAndCheckboxes() {
  guard case .list(let ordered, let start, let items) = MarkdownBlock.parse("3. three\n4. four").first else {
    Issue.record("Expected a list")
    return
  }
  #expect(ordered)
  #expect(start == 3)
  #expect(items.count == 2)
  guard case .list(false, _, let tasks) = MarkdownBlock.parse("- [x] done\n- [ ] todo").first else {
    Issue.record("Expected a task list")
    return
  }
  #expect(tasks.map(\.checked) == [true, false])
}

@Test func tablesKeepHeaderAndRows() {
  guard case .table(let header, let rows, _) = MarkdownBlock.parse("| A | B |\n|---|---|\n| 1 | 2 |").first else {
    Issue.record("Expected a table")
    return
  }
  #expect(header.map(plain) == ["A", "B"])
  #expect(rows.map { $0.map(plain) } == [["1", "2"]])
}

@Test func imagesNeverLoadAndHTMLShowsAsText() {
  guard case .paragraph(let image) = MarkdownBlock.parse("![a cat](https://example.com/cat.png)").first,
    case .paragraph(let bare) = MarkdownBlock.parse("![](cat.png)").first,
    case .paragraph(let html) = MarkdownBlock.parse("<div>raw</div>").first
  else {
    Issue.record("Expected paragraphs")
    return
  }
  #expect(plain(image) == "[Image: a cat]")
  #expect(plain(bare) == "[Image: External image]")
  #expect(plain(html) == "<div>raw</div>")
}

@Test func quotesAndRules() {
  let blocks = MarkdownBlock.parse("> quoted\n\n---")
  guard blocks.count == 2, case .quote(let inner) = blocks[0], case .paragraph(let text) = inner.first
  else {
    Issue.record("Unexpected blocks: \(blocks)")
    return
  }
  #expect(plain(text) == "quoted")
  #expect(blocks[1] == .rule)
}

@MainActor @Test func theCacheParsesOncePerText() {
  let cache = MarkdownCache()
  let first = cache.blocks(id: "i1", text: "**a**")
  #expect(cache.blocks(id: "i1", text: "**a**") == first)
  #expect(cache.parseCount == 1)
  _ = cache.blocks(id: "i1", text: "**a** more")
  #expect(cache.parseCount == 2)
}

@Test func deepNestingFallsBackToPlainText() {
  // swift-markdown converts recursively and overflows the stack near 1,000 levels.
  let deep = String(repeating: ">", count: 5000) + " x"
  #expect(MarkdownBlock.parse(deep) == [.paragraph(AttributedString(deep))])
  let nested = (0..<10).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n")
  var blocks = MarkdownBlock.parse(nested)
  var levels = 0
  while case .list(false, _, let items)? = blocks.first {
    levels += 1
    blocks = Array(items.first?.blocks.dropFirst() ?? [])
  }
  #expect(levels == 10)
}

@Test func bareWebURLsBecomeLinks() {
  guard case .paragraph(let text) = MarkdownBlock.parse("see https://example.com and www.apple.com, not example.org").first
  else {
    Issue.record("Expected a paragraph")
    return
  }
  #expect(text[text.range(of: "https://example.com")!].runs.first?.link == URL(string: "https://example.com"))
  #expect(text[text.range(of: "www.apple.com")!].runs.first?.link == URL(string: "https://www.apple.com"))
  #expect(text[text.range(of: ",")!].runs.first?.link == nil)
  #expect(text[text.range(of: "example.org")!].runs.first?.link == nil)
  // cmark splits text at `_`; the whole URL still links. Code never links.
  guard case .paragraph(let split) = MarkdownBlock.parse("go https://a.com/x_y_z now `https://b.com`").first else {
    Issue.record("Expected a paragraph")
    return
  }
  #expect(split[split.range(of: "https://a.com/x_y_z")!].runs.count == 1)
  #expect(split[split.range(of: "https://a.com/x_y_z")!].runs.first?.link == URL(string: "https://a.com/x_y_z"))
  #expect(split[split.range(of: "https://b.com")!].runs.first?.link == nil)
}

@Test func aBlockedLinksTextIsNeverAutolinked() {
  guard case .paragraph(let text) = MarkdownBlock.parse("[https://evil.com](javascript:x)").first else {
    Issue.record("Expected a paragraph")
    return
  }
  #expect(String(text.characters) == "https://evil.com")
  #expect(text.runs.allSatisfy { $0.link == nil })
}

@Test func inlineAttributesShowLiterally() {
  #expect(MarkdownBlock.parse("a ^[text](rate: 3) b") == [.paragraph(AttributedString("a ^[text](rate: 3) b"))])
}

@Test func unknownBlocksKeepTheirText() {
  let directive = BlockDirective(name: "note", children: Paragraph(Markdown.Text("kept")))
  #expect(MarkdownBlock.block(directive) == .paragraph(AttributedString(directive.format())))
  #expect(directive.format().contains("kept"))
}

@MainActor @Test func theCacheKeepsOneEntryPerItem() {
  let cache = MarkdownCache()
  for n in 0..<5 { _ = cache.blocks(id: "streaming", text: String(repeating: "a", count: n + 1)) }
  #expect(cache.count == 1)
  #expect(cache.parseCount == 5)
  for n in 0..<400 { _ = cache.blocks(id: "i\(n)", text: "t") }
  #expect(cache.count == 400)
  let before = cache.parseCount
  _ = cache.blocks(id: "i399", text: "t")
  #expect(cache.parseCount == before)
  _ = cache.blocks(id: "i0", text: "t")
  #expect(cache.parseCount == before)
  // 401 distinct ids: the oldest, "streaming", was evicted and parses again.
  _ = cache.blocks(id: "streaming", text: "aaaaa")
  #expect(cache.parseCount == before + 1)
  #expect(cache.count == 400)
}

@Test func blocksAreIdentifiedByPositionAndKind() {
  let paragraph = MarkdownBlock.identified(MarkdownBlock.parse("Intro\n\n- one"))
  let list = MarkdownBlock.identified(MarkdownBlock.parse("- intro\n\n- one"))
  #expect(paragraph.map(\.id) == ["0:p", "1:ul"])
  #expect(list.first?.id == "0:ul")
  let short = MarkdownBlock.identified(MarkdownBlock.parse("```swift\nlet a = 1\n"))
  let long = MarkdownBlock.identified(MarkdownBlock.parse("```swift\nlet a = 1\nlet b = 2\n```"))
  #expect(short.first?.id == long.first?.id)
}

@Test func aBareURLDropsAnUnbalancedClosingParenthesis() {
  func links(_ source: String) -> [String] {
    guard case .paragraph(let text) = MarkdownBlock.parse(source).first else { return [] }
    return text.runs.compactMap { $0.link?.absoluteString }
  }
  #expect(links("(see https://a.com/x)") == ["https://a.com/x"])
  #expect(links("https://en.wikipedia.org/wiki/A_(b) is a page") == ["https://en.wikipedia.org/wiki/A_(b)"])
}

@Test func tablesKeepColumnAlignment() {
  guard case .table(_, _, let alignments) = MarkdownBlock.parse("| A | B | C | D |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |").first else {
    Issue.record("Expected a table")
    return
  }
  #expect(alignments == [.leading, .center, .trailing, .leading])
}

@Test func footnotesBecomeNumbersAndANumberedList() {
  let blocks = MarkdownBlock.parse("Muse said so[^a] twice[^b].\n\n[^b]: The second.\n[^a]: The first.\n[^unused]: Dropped.")
  guard case .paragraph(let text) = blocks.first else { Issue.record("Expected a paragraph"); return }
  #expect(String(text.characters) == "Muse said so¹ twice².")
  #expect(blocks.contains(.rule))
  guard case .list(let ordered, _, let items) = blocks.last else { Issue.record("Expected a list"); return }
  #expect(ordered)
  #expect(items.count == 2)
  guard case .paragraph(let first) = items[0].blocks.first else { Issue.record("Expected text"); return }
  #expect(String(first.characters) == "The first.")
}

@Test func footnotesLeaveCodeAndUndefinedReferencesAlone() {
  let source = "Use `[^a]` here, and [^none].\n\n```\n[^a]\n```\n\n[^a]: Note."
  let blocks = MarkdownBlock.parse(source)
  guard case .paragraph(let text) = blocks.first else { Issue.record("Expected a paragraph"); return }
  #expect(String(text.characters) == "Use [^a] here, and [^none].")
  #expect(blocks.contains(.code(language: nil, code: "[^a]")))
  #expect(!blocks.contains(.rule))
}

@Test func footnoteFencesCloseOnlyOnALongEnoughRunOfTheSameMark() {
  let source = "Note[^a].\n\n````\n```\n[^b]: inside\n```\n````\n\n~~~\n```js\n[^c]: in\n~~~ x\n~~~\n\n[^a]: First."
  let blocks = MarkdownBlock.parse(source)
  #expect(blocks.contains(.code(language: nil, code: "```\n[^b]: inside\n```")))
  #expect(blocks.contains(.code(language: nil, code: "```js\n[^c]: in\n~~~ x")))
  guard case .list(true, _, let items) = blocks.last else { Issue.record("Expected a list"); return }
  #expect(items.count == 1)
}

@Test func footnotesCloseAnOpenFenceBeforeTheNotes() {
  let blocks = MarkdownBlock.parse("Note[^a].\n\n[^a]: First.\n\n```\nopen code")
  #expect(blocks.count == 4)
  #expect(blocks.contains(.code(language: nil, code: "open code")))
  #expect(blocks.contains(.rule))
  guard case .list(true, _, let items) = blocks.last, case .paragraph(let note) = items.first?.blocks.first else {
    Issue.record("Expected the notes after the code")
    return
  }
  #expect(String(note.characters) == "First.")
}

@Test func footnoteCodeSpansCloseOnARunOfTheSameLength() {
  func paragraph(_ source: String) -> String? {
    guard case .paragraph(let text) = MarkdownBlock.parse(source + "\n\n[^a]: Note.").first else { return nil }
    return String(text.characters)
  }
  #expect(paragraph("Use ``[^a]`` and a lone ` before [^a].") == "Use [^a] and a lone ` before ¹.")
  // One backtick does not close on two: both runs are plain text.
  #expect(paragraph("Then `a`` [^a].") == "Then `a`` ¹.")
  // A line that opens with a backtick span is not a fence.
  guard case .paragraph(let span) = MarkdownBlock.parse("```a``` b[^a]\n\n[^a]: Note.").first else {
    Issue.record("Expected a paragraph")
    return
  }
  #expect(String(span.characters) == "a b¹")
}

@Test func aDuplicateFootnoteDefinitionAndItsContinuationAreDropped() {
  let blocks = MarkdownBlock.parse("Use[^a].\n\n[^a]: First.\n[^a]: Second.\n    more\n")
  guard case .list(true, _, let items) = blocks.last, case .paragraph(let note) = items.first?.blocks.first else {
    Issue.record("Expected a list")
    return
  }
  #expect(items.count == 1)
  #expect(String(note.characters) == "First.")
  #expect(!blocks.contains(.code(language: nil, code: "more")))
}

@Test func footnoteLabelsIgnoreCase() {
  let blocks = MarkdownBlock.parse("See[^Note] and[^note].\n\n[^NOTE]: Text.")
  guard case .paragraph(let text) = blocks.first else { Issue.record("Expected a paragraph"); return }
  #expect(String(text.characters) == "See¹ and¹.")
  guard case .list(true, _, let items) = blocks.last else { Issue.record("Expected a list"); return }
  #expect(items.count == 1)
}

@MainActor @Test func anInProgressItemParsesAtMostOncePer100ms() {
  let cache = MarkdownCache()
  _ = cache.blocks(id: "a", text: "one", final: false)
  let stale = cache.blocks(id: "a", text: "one two", final: false)
  #expect(stale == MarkdownBlock.parse("one"))
  #expect(cache.blocks(id: "a", text: "one two", final: true) == MarkdownBlock.parse("one two"))
}

@MainActor @Test func anInProgressItemParsesAgainAfter100ms() async throws {
  let cache = MarkdownCache()
  _ = cache.blocks(id: "a", text: "one", final: false)
  try await Task.sleep(for: .milliseconds(150))
  #expect(cache.blocks(id: "a", text: "one two", final: false) == MarkdownBlock.parse("one two"))
  #expect(cache.parseCount == 2)
}

/// Run with `MMAC_MEASURE=1 swift test … --filter measureMarkdownReparse` and report the output.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MMAC_MEASURE"] != nil))
func measureMarkdownReparse() {
  let unit = """
    ## A heading

    A paragraph with **bold**, `code`, and a link to https://example.com/page that runs on long enough.

    - one item
    - two items with *emphasis*

    ```swift
    func example() -> Int { return 42 }
    ```

    """
  for size in [30_000, 60_000, 120_000] {
    let text = String(repeating: unit, count: size / unit.utf8.count + 1)
    var times: [Duration] = []
    for _ in 0..<15 {
      let start = ContinuousClock.now
      _ = MarkdownBlock.parse(text)
      times.append(ContinuousClock.now - start)
    }
    times.sort()
    print("measureMarkdownReparse \(size / 1000) KB median \(times[times.count / 2])")
  }
}
