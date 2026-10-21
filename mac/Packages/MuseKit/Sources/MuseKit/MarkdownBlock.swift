import Foundation
import Markdown

/// One task-list or plain list item.
public struct MarkdownListItem: Equatable, Sendable {
  /// `true` or `false` for a task-list item (`- [x]`), nil for a plain item.
  public let checked: Bool?
  public let blocks: [MarkdownBlock]
}

/// Markdown as blocks of attributed text, ready for SwiftUI. Inline styles travel as
/// `inlinePresentationIntent` and links as `.link`, which SwiftUI's `Text` draws.
public enum MarkdownBlock: Equatable, Sendable {
  case heading(level: Int, text: AttributedString)
  case paragraph(AttributedString)
  /// The code without its final newline. `language` is nil when the fence names none.
  case code(language: String?, code: String)
  case quote([MarkdownBlock])
  case list(ordered: Bool, start: Int, items: [MarkdownListItem])
  case table(header: [AttributedString], rows: [[AttributedString]])
  case rule

  /// Markdown nested deeper than this shows as plain text. A 10-level list is about 23.
  static let maximumDepth = 32

  /// Parses GitHub-flavoured Markdown, as Electron's react-markdown with remark-gfm does.
  /// Smart punctuation is off, as in react-markdown: `--flag` and `"quotes"` stay as typed.
  /// Past `maximumDepth` the whole source is one plain paragraph, so it stays readable and
  /// selectable and swift-markdown's recursive conversion cannot overflow the stack.
  public static func parse(_ source: String) -> [MarkdownBlock] {
    guard MarkdownDepth.deepest(in: source) <= maximumDepth else {
      return [.paragraph(AttributedString(source))]
    }
    return blocks(in: Document(parsing: source, options: .disableSmartOpts))
  }

  static func blocks(in container: Markup) -> [MarkdownBlock] {
    container.children.map(block)
  }

  static func block(_ markup: Markup) -> MarkdownBlock {
    if let heading = markup as? Heading { return .heading(level: heading.level, text: inline(heading)) }
    if let paragraph = markup as? Paragraph { return .paragraph(inline(paragraph)) }
    if let code = markup as? CodeBlock {
      // The fence's first word, as remark's `lang`: "swift title=x" is "swift".
      let language = code.language?.split(whereSeparator: \.isWhitespace).first.map(String.init)
      let text = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
      return .code(language: language, code: text)
    }
    if let quote = markup as? BlockQuote { return .quote(blocks(in: quote)) }
    if let list = markup as? OrderedList {
      return .list(ordered: true, start: Int(list.startIndex), items: list.listItems.map(item))
    }
    if let list = markup as? UnorderedList {
      return .list(ordered: false, start: 1, items: list.listItems.map(item))
    }
    if let table = markup as? Table {
      return .table(
        header: table.head.cells.map { inline($0) },
        rows: table.body.rows.map { row in row.cells.map { inline($0) } })
    }
    if markup is ThematicBreak { return .rule }
    if let html = markup as? HTMLBlock {
      return .paragraph(AttributedString(html.rawHTML.trimmingCharacters(in: .newlines)))
    }
    // A block type this code does not know, say from a swift-markdown update: keep its text.
    return .paragraph(AttributedString(markup.format()))
  }

  static func item(_ item: ListItem) -> MarkdownListItem {
    let checked: Bool? =
      switch item.checkbox {
      case .checked: true
      case .unchecked: false
      case nil: nil
      }
    return MarkdownListItem(checked: checked, blocks: blocks(in: item))
  }

  /// The inline children of `markup` as one attributed string. `inLink` is true inside any
  /// Markdown link, allowed or blocked, so a blocked link's text is never autolinked.
  static func inline(
    _ markup: Markup, intent: InlinePresentationIntent = [], link: URL? = nil, inLink: Bool = false
  ) -> AttributedString {
    var result = AttributedString()
    // cmark splits text at delimiters such as `_`, so adjacent text nodes are joined before
    // bare URLs are found: `https://a.com/x_y_z` links whole.
    var pending = ""
    func flush() {
      guard !pending.isEmpty else { return }
      result += inLink ? styled(pending, intent, link) : autolinked(pending, intent)
      pending = ""
    }
    for child in markup.children {
      if let text = child as? Markdown.Text {
        pending += text.string
        continue
      }
      flush()
      if let code = child as? InlineCode {
        result += styled(code.code, intent.union(.code), link)
      } else if child is Emphasis {
        result += inline(child, intent: intent.union(.emphasized), link: link, inLink: inLink)
      } else if child is Strong {
        result += inline(child, intent: intent.union(.stronglyEmphasized), link: link, inLink: inLink)
      } else if child is Strikethrough {
        result += inline(child, intent: intent.union(.strikethrough), link: link, inLink: inLink)
      } else if let anchor = child as? Link {
        result += inline(child, intent: intent, link: webURL(anchor.destination) ?? link, inLink: true)
      } else if let image = child as? Image {
        let alt = image.plainText.isEmpty ? "External image" : image.plainText
        result += styled("[Image: \(alt)]", intent, link)
      } else if child is SoftBreak {
        result += styled(" ", intent, link)
      } else if child is LineBreak {
        result += styled("\n", intent, link)
      } else if let html = child as? InlineHTML {
        result += styled(html.rawHTML, intent, link)
      } else if let attributes = child as? InlineAttributes {
        // `^[text](attrs)` is swift-markdown's extension, not GFM: show it as typed.
        result += styled("^[", intent, link)
        result += inline(child, intent: intent, link: link, inLink: inLink)
        result += styled("](\(attributes.attributes))", intent, link)
      } else {
        result += inline(child, intent: intent, link: link, inLink: inLink)
      }
    }
    flush()
    return result
  }

  /// One detector for every parse. NSDataDetector is documented as thread-safe.
  static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

  /// `string` with its bare web URLs linked, as remark-gfm's autolink literals: only text that
  /// starts with `http://`, `https://` or `www.`, so `example.org` alone stays text.
  static func autolinked(_ string: String, _ intent: InlinePresentationIntent) -> AttributedString {
    var text = styled(string, intent, nil)
    guard let linkDetector else { return text }
    let whole = NSRange(string.startIndex..., in: string)
    for match in linkDetector.matches(in: string, range: whole) {
      guard let found = Range(match.range, in: string), let range = Range(match.range, in: text)
      else { continue }
      let candidate = String(string[found])
      let lower = candidate.lowercased()
      let destination =
        lower.hasPrefix("http://") || lower.hasPrefix("https://")
        ? candidate : lower.hasPrefix("www.") ? "https://" + candidate : nil
      if let url = webURL(destination) { text[range].link = url }
    }
    return text
  }

  static func styled(_ string: String, _ intent: InlinePresentationIntent, _ link: URL?)
    -> AttributedString
  {
    var text = AttributedString(string)
    if !intent.isEmpty { text.inlinePresentationIntent = intent }
    if let link { text.link = link }
    return text
  }

  /// Only web links open, as in Electron.
  static func webURL(_ destination: String?) -> URL? {
    guard let destination, let url = URL(string: destination),
      ["http", "https"].contains(url.scheme?.lowercased())
    else { return nil }
    return url
  }
}

/// Parsed Markdown per transcript item, so a streamed update re-parses only the item that changed.
/// Keyed by item id, with at most `limit` items.
@MainActor
public final class MarkdownCache {
  public static let shared = MarkdownCache()

  struct Entry {
    let text: String
    let blocks: [MarkdownBlock]
  }

  /// One entry per item id. A streamed item replaces its own entry as its text grows.
  private var entries: [String: Entry] = [:]
  /// Item ids, oldest first, for eviction past `limit`.
  private var order: [String] = []
  private let limit = 400
  /// How many times `blocks(id:text:)` parsed. Tests read it.
  private(set) var parseCount = 0

  public init() {}

  var count: Int { entries.count }

  public func blocks(id: String, text: String) -> [MarkdownBlock] {
    if let entry = entries[id], entry.text == text { return entry.blocks }
    let parsed = MarkdownBlock.parse(text)
    parseCount += 1
    if entries[id] == nil {
      order.append(id)
      if order.count > limit { entries[order.removeFirst()] = nil }
    }
    entries[id] = Entry(text: text, blocks: parsed)
    return parsed
  }
}
