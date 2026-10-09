import Foundation
import XCTest

@testable import PolkaTools

final class CoverageTests: XCTestCase {
  let root = URL(fileURLWithPath: "/synthetic/project")
  func file(_ path: String, _ covered: Int, _ total: Int) -> [String: Any] {
    [
      "filename": root.appendingPathComponent(path).path,
      "summary": ["lines": ["covered": covered, "count": total]],
    ]
  }
  func data(_ files: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["data": [["files": files]]])
  }
  func testMergedExportContainsEveryXCTestBinary() {
    let args = Coverage.exportArguments(
      codecov: root.appendingPathComponent(
        "native-app/.build/Products/Debug/codecov/PolkaNative.json"))
    XCTAssertEqual(args.filter { $0.contains(".xctest/") }.count, 3)
    XCTAssertEqual(args.filter { $0 == "-object" }.count, 2)
    XCTAssertTrue(args.contains { $0.hasSuffix("codecov/default.profdata") })
  }
  func testNativeEngineExportsCombinedPackageTestsInsteadOfMissingTargetBundles() {
    let args = Coverage.exportArguments(
      codecov: root.appendingPathComponent(
        "native-app/.build/arm64-apple-macosx/debug/codecov/PolkaNative.json"),
      nativeEngine: true)
    XCTAssertEqual(
      args.filter { $0.contains(".xctest/") },
      [
        root.appendingPathComponent(
          "native-app/.build/arm64-apple-macosx/debug/PolkaNativePackageTests.xctest/Contents/MacOS/PolkaNativePackageTests"
        ).path
      ])
    XCTAssertFalse(args.contains("-object"))
    XCTAssertTrue(args.contains { $0.hasSuffix("codecov/default.profdata") })
  }
  func testUnexecutedPlatformAndUIAreIncluded() throws {
    let report = try Coverage.summary(
      data([
        file("native-app/Sources/PolkaCore/History.swift", 90, 100),
        file("native-app/Sources/PolkaApp/Platform/Service.swift", 0, 100),
        file("native-app/Sources/PolkaApp/UI/View.swift", 10, 100),
        file("native-app/Sources/PolkaApp/NativeApplication.swift", 20, 100),
      ]), root: root)
    XCTAssertEqual(report.groups["business"]?.percent, 45)
    XCTAssertEqual(report.groups["overall"]?.percent, 30)
    XCTAssertFalse(try Coverage.gate(report).passed)
  }
  func testDriversDependenciesAndExternalFilesCannotInflateCoverage() throws {
    let report = try Coverage.summary(
      data([
        file("native-app/Sources/PolkaCore/History.swift", 1, 2),
        file("native-app/Sources/PolkaApp/UI/NativeSmokeFlows.swift", 500, 500),
        file("native-app/Sources/PolkaCoreProbe/main.swift", 500, 500),
        file("native-app/.build/Generated.swift", 500, 500),
        [
          "filename": "/other/native-app/Sources/PolkaCore/History.swift",
          "summary": ["lines": ["covered": 500, "count": 500]],
        ],
      ]), root: root)
    XCTAssertEqual(report.groups["overall"]?.percent, 50)
    XCTAssertEqual(report.files.count, 1)
  }
  func testMissingSourcesDuplicateExportsAndInvalidCountsFail() throws {
    let source = file("native-app/Sources/PolkaCore/History.swift", 1, 2)
    XCTAssertThrowsError(try Coverage.summary(data([source, source]), root: root))
    XCTAssertThrowsError(
      try Coverage.summary(
        data([source]), root: root,
        sourceFiles: [
          root.appendingPathComponent("native-app/Sources/PolkaApp/NativeApplication.swift")
        ]))
    XCTAssertThrowsError(
      try Coverage.summary(
        data([file("native-app/Sources/PolkaCore/Invalid.swift", 3, 2)]), root: root))
    XCTAssertFalse(try Coverage.gate(Coverage.summary(data([]), root: root)).passed)
  }
  func testGateUsesUnroundedPercentage() throws {
    let report = try Coverage.summary(
      data([file("native-app/Sources/PolkaCore/History.swift", 75999, 100000)]), root: root)
    XCTAssertFalse(try Coverage.gate(report, thresholds: ["business": 76]).passed)
    XCTAssertTrue(try Coverage.gate(report, thresholds: ["business": 75.999]).passed)
    XCTAssertThrowsError(try Coverage.gate(report, thresholds: ["business": .nan]))
  }
}
