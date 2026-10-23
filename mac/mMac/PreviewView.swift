import MuseKit
import SwiftUI
import WebKit

/// The Preview tab: a site beside the conversation, as Desktop's Browser pane for a dev server.
struct PreviewView: View {
  let project: String
  @State private var address = ""
  @State private var page = WebPage()
  @State private var failure: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Button("Back", systemImage: "chevron.left") { page.goBack() }
          .labelStyle(.iconOnly).disabled(!page.canGoBack).help("Back")
        Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
          .labelStyle(.iconOnly).disabled(page.url == nil).help("Reload")
        TextField("localhost:4321", text: $address)
          .textFieldStyle(.roundedBorder)
          .onSubmit(load)
          .accessibilityLabel("Preview address")
          .accessibilityIdentifier("preview-url")
        Button("Open in Safari", systemImage: "safari") {
          if let url = page.url { NSWorkspace.shared.open(url) }
        }
        .labelStyle(.iconOnly).disabled(page.url == nil).help("Open in Safari")
      }
      .padding(8)
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.red).padding(.horizontal, 8).padding(.bottom, 6)
      }
      Text(page.title).font(.caption).foregroundStyle(.themeSecondary).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
        .accessibilityIdentifier("preview-title")
      Divider()
      WebViewBox(page: page)
    }
    .task(id: project) {
      address = MMacApp.appStorage.string(forKey: PreviewRules.key(for: project)) ?? ""
    }
  }

  private func load() {
    guard let url = PreviewRules.url(from: address) else {
      failure = "Enter an address such as localhost:4321."
      return
    }
    failure = nil
    MMacApp.appStorage.set(url.absoluteString, forKey: PreviewRules.key(for: project))
    page.load(url) { failure = $0 }
  }
}

/// One `WKWebView` and what the toolbar reads from it. `@Observable`, so the buttons follow it.
@MainActor @Observable
final class WebPage {
  let view = WKWebView()
  private(set) var title = ""
  private(set) var url: URL?
  private(set) var canGoBack = false
  private let watcher = Watcher()
  private var observations: [NSKeyValueObservation] = []

  init() {
    watcher.onChange = { [weak self] in self?.read() }
    view.navigationDelegate = watcher
    // The toolbar follows the page by key-value observation too, which fires for every
    // navigation on the main thread, whatever the delegate does.
    observations = [
      view.observe(\.title, options: [.new]) { [weak self] _, _ in self?.read() },
      view.observe(\.url, options: [.new]) { [weak self] _, _ in self?.read() },
      view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.read() },
    ]
  }

  func load(_ url: URL, failed: @escaping (String) -> Void) {
    watcher.onFailure = failed
    if url.isFileURL {
      view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else {
      view.load(URLRequest(url: url))
    }
  }

  func goBack() { view.goBack() }
  func reload() { view.reload() }

  private func read() {
    title = view.title ?? ""
    url = view.url
    canGoBack = view.canGoBack
  }

  /// The navigation delegate: a plain object, since WebKit calls it on the main thread.
  private final class Watcher: NSObject, WKNavigationDelegate {
    var onChange: () -> Void = {}
    var onFailure: (String) -> Void = { _ in }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onChange() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
      onFailure(error.localizedDescription)
      onChange()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
      onFailure(error.localizedDescription)
      onChange()
    }
  }
}

struct WebViewBox: NSViewRepresentable {
  let page: WebPage
  func makeNSView(context: Context) -> WKWebView { page.view }
  func updateNSView(_ view: WKWebView, context: Context) {}
}
