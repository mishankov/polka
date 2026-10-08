import Foundation
import XCTest

@testable import PolkaTools

final class MediaProbeTests: XCTestCase {
  func testActualNativeClassifierAgainstTwelveDeviceFixturesWithoutHardware() throws {
    let root = try Files.temporary("polka-media-probe-test")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try String(
      contentsOf: TestSupport.root.appendingPathComponent("native/MediaProbe.swift"),
      encoding: .utf8)
    let pieces = source.components(separatedBy: "// CLI entry point.")
    guard pieces.count == 2 else {
      throw ToolError(
        "Refusing to compile media fixture without removing the hardware CLI entry point")
    }
    let fixture = #"""
      func check(_ name: String, _ expected: String, _ processes: [AudioObjectID]?,
                 _ running: [AudioObjectID:UInt32], _ devices: [AudioObjectID:[AudioObjectID]],
                 _ streams: [AudioObjectID:[AudioObjectID]]) {
        let actual = microphoneState(processes: processes, runningInput: { running[$0] },
          inputDevices: { devices[$0] }, inputStreams: { streams[$0] })
        precondition(actual == expected, "\(name): \(actual), expected \(expected)")
      }
      check("No audio", "inactive", [], [:], [:], [:])
      check("Screenshot shutter / CoreSpeech without devices", "inactive", [1], [1:1], [1:[]], [:])
      check("Playback on a duplex device", "inactive", [1], [1:0], [1:[10]], [10:[100]])
      check("Device with no input streams", "inactive", [1], [1:1], [1:[10]], [10:[]])
      check("Microphone input", "active", [1], [1:1], [1:[10]], [10:[100]])
      check("Virtual microphone input", "active", [1], [1:1], [1:[20]], [20:[200]])
      check("Screenshot plus a real microphone", "active", [1,2], [1:1,2:1], [1:[],2:[10]], [10:[100]])
      check("Unreadable process list", "unknown", nil, [:], [:], [:])
      check("Unreadable activity", "unknown", [1], [:], [:], [:])
      check("Unreadable device list", "unknown", [1], [1:1], [:], [:])
      check("Unreadable streams", "unknown", [1], [1:1], [1:[10]], [:])
      check("One failing process cannot hide real input", "active", [1,2], [2:1], [2:[10]], [10:[100]])
      print("12 native microphone cases passed")
      """#
    let main = root.appendingPathComponent("main.swift")
    let binary = root.appendingPathComponent("test-media-probe")
    try TestSupport.write(pieces[0] + fixture, to: main)
    try Command.run(
      "/usr/bin/xcrun",
      [
        "swiftc", main.path, "-o", binary.path, "-framework", "CoreAudio", "-framework",
        "CoreMediaIO", "-framework", "AVFoundation",
      ])
    XCTAssertTrue(try Command.capture(binary.path).contains("12 native microphone cases passed"))
  }
}
