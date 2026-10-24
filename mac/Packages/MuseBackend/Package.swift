// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MuseBackend",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "MuseBackend", targets: ["MuseBackend"]),
    // The fake transport, for tests in this package and in MuseKit.
    .library(name: "MuseBackendTesting", targets: ["MuseBackendTesting"]),
  ],
  targets: [
    .target(name: "MuseBackend"),
    .target(name: "MuseBackendTesting", dependencies: ["MuseBackend"]),
    .testTarget(name: "MuseBackendTests", dependencies: ["MuseBackend", "MuseBackendTesting"]),
  ]
)
