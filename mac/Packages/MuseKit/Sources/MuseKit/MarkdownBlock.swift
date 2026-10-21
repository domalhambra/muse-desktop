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

  /// Parses GitHub-flavoured Markdown, as Electron's react-markdown with remark-gfm does.
  /// Smart punctuation is off, as in react-markdown: `--flag` and `"quotes"` stay as typed.
  public static func parse(_ source: String) -> [MarkdownBlock] {
    blocks(in: Document(parsing: source, options: .disableSmartOpts))
  }

  static func blocks(in container: Markup) -> [MarkdownBlock] {
    container.children.compactMap(block)
  }

  static func block(_ markup: Markup) -> MarkdownBlock? {
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
    return nil
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

  /// The inline children of `markup` as one attributed string.
  static func inline(_ markup: Markup, intent: InlinePresentationIntent = [], link: URL? = nil)
    -> AttributedString
  {
    var result = AttributedString()
    for child in markup.children {
      if let text = child as? Markdown.Text {
        result += styled(text.string, intent, link)
      } else if let code = child as? InlineCode {
        result += styled(code.code, intent.union(.code), link)
      } else if child is Emphasis {
        result += inline(child, intent: intent.union(.emphasized), link: link)
      } else if child is Strong {
        result += inline(child, intent: intent.union(.stronglyEmphasized), link: link)
      } else if child is Strikethrough {
        result += inline(child, intent: intent.union(.strikethrough), link: link)
      } else if let anchor = child as? Link {
        result += inline(child, intent: intent, link: webURL(anchor.destination) ?? link)
      } else if let image = child as? Image {
        let alt = image.plainText.isEmpty ? "External image" : image.plainText
        result += styled("[Image: \(alt)]", intent, link)
      } else if child is SoftBreak {
        result += styled(" ", intent, link)
      } else if child is LineBreak {
        result += styled("\n", intent, link)
      } else if let html = child as? InlineHTML {
        result += styled(html.rawHTML, intent, link)
      } else {
        result += inline(child, intent: intent, link: link)
      }
    }
    return result
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
@MainActor
public final class MarkdownCache {
  public static let shared = MarkdownCache()

  struct Key: Hashable {
    let id: String
    let text: String
  }

  private var entries: [Key: [MarkdownBlock]] = [:]
  private var order: [Key] = []
  private let limit = 400
  /// How many times `blocks(id:text:)` parsed. Tests read it.
  private(set) var parseCount = 0

  public init() {}

  public func blocks(id: String, text: String) -> [MarkdownBlock] {
    let key = Key(id: id, text: text)
    if let cached = entries[key] { return cached }
    let parsed = MarkdownBlock.parse(text)
    parseCount += 1
    entries[key] = parsed
    order.append(key)
    if order.count > limit { entries[order.removeFirst()] = nil }
    return parsed
  }
}
