// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PolkaNative",
  defaultLocalization: "en",
  platforms: [.macOS("27.0")],
  products: [
    .library(name: "PolkaCore", targets: ["PolkaCore"]),
    .executable(name: "PolkaNative", targets: ["PolkaApp"]),
    .executable(name: "PolkaCoreProbe", targets: ["PolkaCoreProbe"]),
    .executable(name: "PolkaSyncFixture", targets: ["PolkaSyncFixture"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.83.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.33.0"),
    .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .systemLibrary(name: "CCommonCrypto"),
    .target(
      name: "PolkaCore", dependencies: ["CSQLite", "CCommonCrypto"],
      resources: [
        .copy("Resources/emoji-data.json"), .process("Resources/en.lproj"),
        .process("Resources/ru.lproj"),
      ]),
    .executableTarget(
      name: "PolkaApp",
      dependencies: [
        "PolkaCore", .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "X509", package: "swift-certificates"),
      ]),
    .executableTarget(name: "PolkaCoreProbe", dependencies: ["PolkaCore"]),
    .executableTarget(
      name: "PolkaSyncFixture",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
      ]),
    .testTarget(name: "PolkaCoreTests", dependencies: ["PolkaCore"]),
    .testTarget(
      name: "PolkaPlatformTests", dependencies: ["PolkaApp", "PolkaCore", "PolkaSyncFixture"]),
    .testTarget(name: "PolkaUITests", dependencies: ["PolkaApp", "PolkaCore"]),
  ],
  swiftLanguageModes: [.v5]
)
