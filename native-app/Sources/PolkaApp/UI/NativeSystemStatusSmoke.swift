import AppKit
import Darwin
import Foundation
import PolkaCore

/// Optional, real sampling plus SwiftUI rendering inside the isolated desktop fixture.
@MainActor func nativeSystemStatusMeasure(model: NativeUIModel, directory: URL) async throws {
  precondition(NativeProfile.isolatedFixture)
  func cpu() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }
  func footprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
  }
  model.systemStatus = NativeSystemStatusFixtures.snapshot("normal")
  try await Task.sleep(nanoseconds: 500_000_000)
  let baselineCPU = cpu()
  let baselineStart = ProcessInfo.processInfo.systemUptime
  try await Task.sleep(nanoseconds: 10_000_000_000)
  let baselineSeconds = ProcessInfo.processInfo.systemUptime - baselineStart
  let baselinePercent = (cpu() - baselineCPU) / baselineSeconds * 100
  let beforeMemory = footprint()
  let activeCPU = cpu()
  let activeStart = ProcessInfo.processInfo.systemUptime
  let monitor = SystemStatusMonitor(model: model, fixture: false)
  defer { monitor.stop() }
  try await Task.sleep(nanoseconds: 10_000_000_000)
  let activeSeconds = ProcessInfo.processInfo.systemUptime - activeStart
  let activePercent = (cpu() - activeCPU) / activeSeconds * 100
  let afterMemory = footprint()
  let report: [String: Any] = [
    "scope":
      "Isolated macOS VM, debug app, real probes and visible SwiftUI overview; baseline is the same synthetic overview without sampling",
    "baselineSeconds": baselineSeconds, "activeSeconds": activeSeconds,
    "baselineOneCoreCPUPercent": baselinePercent, "activeOneCoreCPUPercent": activePercent,
    "additionalCPUPercentagePoints": activePercent - baselinePercent,
    "sampleCount": monitor.sampleCount,
    "footprintBeforeBytes": beforeMemory.map { $0 as Any } ?? NSNull(),
    "footprintAfterBytes": afterMemory.map { $0 as Any } ?? NSNull(),
    "battery": model.systemStatus.battery.state.rawValue,
    "memory": model.systemStatus.memory.state.rawValue,
    "storage": model.systemStatus.storage.state.rawValue,
    "network": model.systemStatus.network.state.rawValue,
  ]
  try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: directory.appendingPathComponent("system-status-overhead.json"))
  guard (4...6).contains(monitor.sampleCount) else {
    throw PolkaCoreError.invalid("Unexpected System Status sampling frequency")
  }
}

/// Keep the resource suite independent of the larger shared keyboard routine.
/// Callbacks use the same AppKit input and screenshot helpers as the other suites.
@MainActor func nativeSystemStatusSmoke(
  application: NativeApplication, shelf: NSWindow, model: NativeUIModel, platform: NativePlatform,
  environment: [String: String], screenshotDirectory: URL?,
  post: (UInt16) -> Void, enter: () -> Void, settle: () async -> Void,
  screenshot: (String) async -> Void, frame: (String) -> NSRect?,
  clickAccessible: (String) -> Void, keyboardState: () -> String
) async -> [String] {
  guard NativeProfile.isolatedFixture else { return ["native smoke requires an isolated profile"] }
  var failures: [String] = []
  func wait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
  }
  await application.show("apps")
  await settle()
  model.query = "battery"
  await settle()
  post(125)
  enter()
  if !(await wait({ model.destination == "system-status" && !model.busy && shelf.isKeyWindow })) {
    failures.append("Search, Down, Enter did not open System Status; " + keyboardState())
  }
  if environment["POLKA_NATIVE_SYSTEM_STATUS_MEASURE"] == "1", let screenshotDirectory {
    do { try await nativeSystemStatusMeasure(model: model, directory: screenshotDirectory) } catch {
      failures.append("System Status overhead measurement failed: \(error)")
    }
  }
  for state in ["normal", "warning", "unavailable", "zero-traffic"] {
    model.systemStatus = NativeSystemStatusFixtures.snapshot(state)
    await screenshot("system-status-" + state)
    for category in ["battery", "memory", "storage", "network"] {
      if let frame = frame("system-status-" + category) {
        if !shelf.frame.insetBy(dx: -1, dy: -1).contains(frame) {
          failures.append("System Status category is clipped: \(category) in \(state)")
        }
      } else {
        failures.append("Missing accessible System Status category: " + category)
      }
    }
    let responder = shelf.firstResponder
    let selected = model.selectedID
    model.systemStatus.accept(NativeSystemStatusFixtures.snapshot(state))
    await settle()
    if shelf.firstResponder !== responder || model.selectedID != selected {
      failures.append("Resource updates changed focus or selection")
    }
  }
  model.systemStatus = NativeSystemStatusFixtures.snapshot("normal")
  model.systemStatus.activity.reset()
  model.systemStatus.network.value?.rates = nil
  await screenshot("system-status-collecting")
  do {
    let original = model.settings.languagePreference.rawValue
    try await platform.handle(NativeUICommand("settings.language", strings: ["value": "ru"]))
    model.systemStatus = NativeSystemStatusFixtures.snapshot("normal")
    await screenshot("system-status-normal-ru")
    model.systemStatus = NativeSystemStatusFixtures.snapshot("unavailable")
    await screenshot("system-status-unavailable-ru")
    try await platform.handle(NativeUICommand("settings.language", strings: ["value": original]))
  } catch { failures.append("Could not verify Russian System Status: \(error)") }
  post(51)
  if !(await wait({ model.destination == "apps" && !model.busy })) {
    failures.append("Backspace did not return System Status to apps")
  }
  model.query = "сеть"
  await settle()
  clickAccessible("result-builtin:system-status")
  if !(await wait({ model.destination == "system-status" && !model.busy })) {
    failures.append("Mouse did not open System Status from Russian alias")
  }
  post(53)
  if !(await wait({ !model.visible && !shelf.isVisible })) {
    failures.append("Escape did not dismiss System Status")
  }
  await application.show("clipboard")
  await settle()
  return failures
}
