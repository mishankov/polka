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
