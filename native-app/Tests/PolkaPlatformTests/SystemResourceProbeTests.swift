import Darwin
import PolkaCore
import XCTest

@testable import PolkaApp

final class SystemResourceProbeTests: XCTestCase {
  func testLocalProbesAndNetworkWarmup() async {
    let probe = SystemResourceProbe()
    let snapshot = await probe.sample(session: 1)
    XCTAssertEqual(snapshot.battery.state, .ready)
    XCTAssertEqual(snapshot.memory.state, .ready)
    XCTAssertEqual(snapshot.memory.value?.total, ProcessInfo.processInfo.physicalMemory)
    XCTAssertEqual(snapshot.storage.state, .ready)
    XCTAssertEqual(snapshot.storage.value?.path, "/System/Volumes/Data")
    XCTAssertEqual(snapshot.network.state, .ready)
    XCTAssertNil(snapshot.network.value?.rates)
    let resumed = await probe.sample(session: 2)
    XCTAssertNil(resumed.network.value?.rates)
  }
  /// Optional measurement, separate from correctness gates. Reads only local metrics.
  func testMonitoringOverhead() async throws {
    guard ProcessInfo.processInfo.environment["POLKA_MEASURE_SYSTEM_STATUS"] == "1" else {
      throw XCTSkip(
        "Run with POLKA_MEASURE_SYSTEM_STATUS=1 to measure a 20-second sampling session")
    }
    func cpu() -> Double {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    let probe = SystemResourceProbe()
    let startCPU = cpu()
    let start = ProcessInfo.processInfo.systemUptime
    var durations: [Double] = []
    var snapshot = SystemStatusSnapshot()
    for _ in 0..<10 {
      let sampleStart = ProcessInfo.processInfo.systemUptime
      snapshot = await probe.sample(session: 1)
      durations.append((ProcessInfo.processInfo.systemUptime - sampleStart) * 1000)
      try await Task.sleep(nanoseconds: 2_000_000_000)
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let cpuSeconds = cpu() - startCPU
    let report: [String: Any] = [
      "samples": durations.count, "intervalSeconds": 2, "wallSeconds": elapsed,
      "cpuSeconds": cpuSeconds, "oneCoreCPUPercent": cpuSeconds / elapsed * 100,
      "meanProbeMilliseconds": durations.reduce(0, +) / Double(durations.count),
      "maxProbeMilliseconds": durations.max()!,
      "battery": snapshot.battery.state.rawValue, "memory": snapshot.memory.state.rawValue,
      "storage": snapshot.storage.state.rawValue, "network": snapshot.network.state.rawValue,
      "scope":
        "Debug local probes in XCTest; excludes shelf rendering and includes XCTest/task scheduling",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print("System Status overhead:\n" + String(decoding: data, as: UTF8.self))
    if let path = ProcessInfo.processInfo.environment["POLKA_SYSTEM_STATUS_MEASUREMENT"] {
      try data.write(to: URL(fileURLWithPath: path))
    }
    XCTAssertEqual(snapshot.memory.state, .ready)
  }
}
