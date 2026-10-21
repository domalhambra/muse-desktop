// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MuseBackend",
  platforms: [.macOS(.v15)],
  products: [.library(name: "MuseBackend", targets: ["MuseBackend"])],
  targets: [
    .target(name: "MuseBackend"),
    .testTarget(name: "MuseBackendTests", dependencies: ["MuseBackend"]),
  ]
)
