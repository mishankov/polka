// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PolkaTools",
  platforms: [.macOS("27.0")],
  products: [
    .library(name: "PolkaTools", targets: ["PolkaTools"]),
    .executable(name: "polka-tool", targets: ["PolkaTool"]),
    .executable(name: "polka-tool-fixture", targets: ["PolkaToolFixture"]),
  ],
  targets: [
    .systemLibrary(name: "CCommonCrypto"),
    .target(name: "PolkaTools", dependencies: ["CCommonCrypto"]),
    .executableTarget(name: "PolkaTool", dependencies: ["PolkaTools"]),
    .executableTarget(name: "PolkaToolFixture", dependencies: ["PolkaTools"]),
    .testTarget(name: "PolkaToolsTests", dependencies: ["PolkaTools", "PolkaToolFixture"]),
  ],
  swiftLanguageModes: [.v5]
)
