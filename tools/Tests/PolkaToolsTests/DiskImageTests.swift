import Foundation
import XCTest

@testable import PolkaTools

final class DiskImageTests: XCTestCase {
  private func result(_ status: Int32 = 0, error: String = "") -> Command.Result {
    Command.Result(status: status, stdout: Data(), stderr: Data(error.utf8))
  }

  func testBusyCreationRetriesCleanOutputAndVerifiesSuccessfulImage() throws {
    let root = try Files.temporary("polka-dmg-test")
    defer { try? ToolFiles.remove(root) }
    let image = root.appendingPathComponent("Polka.dmg")
    try Data("old image".utf8).write(to: image)
    var creates = 0
    var verifies = 0
    var delays: [TimeInterval] = []
    try PackageTool.createDiskImage(
      stage: root, image: image, volumeName: "Polka", environment: ["SYNTHETIC": "kept"],
      execute: { executable, arguments, environment in
        XCTAssertEqual(executable, "/usr/bin/hdiutil")
        XCTAssertEqual(environment, ["SYNTHETIC": "kept", "LC_ALL": "C"])
        if arguments.first == "create" {
          creates += 1
          XCTAssertEqual(
            arguments,
            [
              "create", "-ov", "-volname", "Polka", "-srcfolder", root.path,
              "-format", "UDZO", image.path,
            ])
          XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
          try Data((creates < 3 ? "partial" : "complete").utf8).write(to: image)
          return self.result(
            creates < 3 ? 1 : 0,
            error: creates < 3
              ? "hdiutil: create failed - Resource busy\n" : "")
        }
        verifies += 1
        XCTAssertEqual(arguments, ["verify", image.path])
        XCTAssertEqual(try String(contentsOf: image, encoding: .utf8), "complete")
        return self.result()
      },
      wait: { delay, environment in
        XCTAssertEqual(environment, ["SYNTHETIC": "kept", "LC_ALL": "C"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        delays.append(delay)
      })
    XCTAssertEqual(creates, 3)
    XCTAssertEqual(verifies, 1)
    XCTAssertEqual(delays, [2, 4])
    XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
  }

  func testPermanentCreationErrorAndExhaustedBusyRetriesFailWithoutVerification() throws {
    for (message, expectedAttempts) in [
      ("hdiutil: create failed - Resource busy\n", 3),
      ("hdiutil: create failed - Permission denied\n", 1),
    ] {
      let root = try Files.temporary("polka-dmg-failure-test")
      defer { try? ToolFiles.remove(root) }
      let image = root.appendingPathComponent("Polka.dmg")
      var attempts = 0
      XCTAssertThrowsError(
        try PackageTool.createDiskImage(
          stage: root, image: image, volumeName: "Polka", environment: [:],
          execute: { _, arguments, _ in
            XCTAssertEqual(arguments.first, "create")
            attempts += 1
            try Data("partial".utf8).write(to: image)
            return self.result(1, error: message)
          }, wait: { _, _ in })
      ) { error in
        XCTAssertEqual((error as? ToolError)?.exitCode, 1)
      }
      XCTAssertEqual(attempts, expectedAttempts)
      XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
    }
  }

  func testFailedVerificationRemainsFatalAndRemovesImage() throws {
    let root = try Files.temporary("polka-dmg-verify-test")
    defer { try? ToolFiles.remove(root) }
    let image = root.appendingPathComponent("Polka.dmg")
    var commands: [String] = []
    XCTAssertThrowsError(
      try PackageTool.createDiskImage(
        stage: root, image: image, volumeName: "Polka", environment: [:],
        execute: { _, arguments, _ in
          commands.append(arguments[0])
          try Data("corrupt".utf8).write(to: image)
          return self.result(arguments[0] == "create" ? 0 : 2)
        }, wait: { _, _ in XCTFail("Verification must not retry") })
    ) { error in
      XCTAssertEqual((error as? ToolError)?.exitCode, 2)
    }
    XCTAssertEqual(commands, ["create", "verify"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
  }

  func testCancellationDuringBackoffStopsRetriesAndCleansOutput() throws {
    let root = try Files.temporary("polka-dmg-cancel-test")
    defer { try? ToolFiles.remove(root) }
    let image = root.appendingPathComponent("Polka.dmg")
    var attempts = 0
    XCTAssertThrowsError(
      try PackageTool.createDiskImage(
        stage: root, image: image, volumeName: "Polka", environment: [:],
        execute: { _, _, _ in
          attempts += 1
          try Data("partial".utf8).write(to: image)
          return self.result(1, error: "hdiutil: create failed - Resource busy\n")
        }, wait: { _, _ in throw CancellationError() })
    ) { error in
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(attempts, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
  }

  func testCreatesAndVerifiesRealSyntheticDiskImage() throws {
    let root = try Files.temporary("polka-dmg-real-test")
    defer { try? ToolFiles.remove(root) }
    let stage = root.appendingPathComponent("stage")
    try Files.mkdir(stage)
    try Data("Synthetic package fixture".utf8).write(
      to: stage.appendingPathComponent("fixture.txt"))
    try FileManager.default.createSymbolicLink(
      at: stage.appendingPathComponent("Applications"),
      withDestinationURL: URL(fileURLWithPath: "/Applications"))
    let image = root.appendingPathComponent("Polka fixture.dmg")
    try PackageTool.createDiskImage(
      stage: stage, image: image, volumeName: "Polka fixture",
      environment: ProcessInfo.processInfo.environment)
    XCTAssertGreaterThan(try Data(contentsOf: image).count, 0)
  }
}
