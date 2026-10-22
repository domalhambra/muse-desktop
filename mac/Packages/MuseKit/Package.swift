// swift-tools-version: 6.0
import PackageDescription

// mMac's logic that is not drawing: Markdown, transcript grouping, the sidebar and the
// conversation state. The app target keeps only views. Everything here runs under swift test.
let package = Package(
  name: "MuseKit",
  platforms: [.macOS(.v15)],
  products: [.library(name: "MuseKit", targets: ["MuseKit"])],
  dependencies: [
    .package(path: "../MuseBackend"),
    // Apple's Markdown parser, on cmark-gfm. Pinned exactly: update it on purpose.
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    // swift-markdown's own parser, used directly to measure nesting before swift-markdown
    // converts it recursively. Pinned to the version swift-markdown 0.9.0 resolves.
    .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
  ],
  targets: [
    .target(
      name: "MuseKit",
      dependencies: [
        .product(name: "MuseBackend", package: "MuseBackend"),
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "cmark-gfm", package: "swift-cmark"),
        .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
      ]),
    .testTarget(
      name: "MuseKitTests",
      dependencies: [
        "MuseKit",
        .product(name: "MuseBackendTesting", package: "MuseBackend"),
        // MarkdownBlockTests.swift imports Markdown directly.
        .product(name: "Markdown", package: "swift-markdown"),
      ]),
  ]
)
