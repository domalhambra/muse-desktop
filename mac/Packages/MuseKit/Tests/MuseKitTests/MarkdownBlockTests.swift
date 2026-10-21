import Foundation
import Testing
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
  guard case .table(let header, let rows) = MarkdownBlock.parse("| A | B |\n|---|---|\n| 1 | 2 |").first else {
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
