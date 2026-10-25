import cmark_gfm
import cmark_gfm_extensions

/// How deeply Markdown nests, measured with cmark before swift-markdown sees it.
///
/// swift-markdown converts cmark's tree recursively, about 8 KB of stack per level, and
/// overflows near 1,000 levels on the main thread. cmark parses iteratively, so this walk is
/// safe at any depth.
enum MarkdownDepth {
  /// The deepest node in the tree, the document itself counting as 1. Parses as swift-markdown
  /// 0.9.0 does (its `CommonMarkConverter.parseString`): table spans and the table,
  /// strikethrough and tasklist extensions. Smart punctuation and source positions do not
  /// change the tree's shape.
  static func deepest(in source: String) -> Int {
    cmark_gfm_core_extensions_ensure_registered()
    guard let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS) else { return .max }
    defer { cmark_parser_free(parser) }
    for name in ["table", "strikethrough", "tasklist"] {
      cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
    }
    cmark_parser_feed(parser, source, source.utf8.count)
    guard let root = cmark_parser_finish(parser) else { return .max }
    defer { cmark_node_free(root) }
    guard let iterator = cmark_iter_new(root) else { return .max }
    defer { cmark_iter_free(iterator) }

    // The open nodes from the root down. Every event's node is a child of the path's last
    // node, so pop back to its parent first; an exit event pops the node itself.
    var path: [UnsafeMutablePointer<cmark_node>] = []
    var deepest = 0
    while true {
      let event = cmark_iter_next(iterator)
      if event == CMARK_EVENT_DONE { break }
      guard let node = cmark_iter_get_node(iterator) else { break }
      let parent = cmark_node_parent(node)
      while let last = path.last, last != parent { path.removeLast() }
      if event == CMARK_EVENT_ENTER {
        path.append(node)
        deepest = max(deepest, path.count)
      }
    }
    return deepest
  }
}
