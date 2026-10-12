import PolkaCore
import XCTest

final class SystemStatusTests: XCTestCase {
  func testBatteryTransitionsAndUnknownEstimates() {
    let charging = BatteryStatus.normalize(
      current: 50, maximum: 100, charging: true,
      charged: false, externalPower: true, minutes: 30)
    XCTAssertEqual(charging?.mode, .charging)
    XCTAssertEqual(charging?.estimatedMinutes, 30)
    for estimate in [-1, 0] {
      XCTAssertNil(
        BatteryStatus.normalize(
          current: 0, maximum: 100, charging: false,
          charged: false, externalPower: false, minutes: estimate)?.estimatedMinutes)
    }
    XCTAssertEqual(
      BatteryStatus.normalize(
        current: 0, maximum: 100, charging: false,
        charged: false, externalPower: false, minutes: nil)?.percentage, 0)
    XCTAssertEqual(
      BatteryStatus.normalize(
        current: 80, maximum: 100, charging: false,
        charged: false, externalPower: true, minutes: 99)?.mode, .pluggedIn)
    let full = BatteryStatus.normalize(
      current: 100, maximum: 100, charging: false,
      charged: true, externalPower: true, minutes: 99)
    XCTAssertEqual(full?.mode, .full)
    XCTAssertNil(full?.estimatedMinutes)
    for (current, maximum) in [(0, 0), (-1, 100), (101, 100)] {
      XCTAssertNil(
        BatteryStatus.normalize(
          current: current, maximum: maximum,
          charging: false, charged: false, externalPower: false, minutes: nil))
    }
  }
  func testMemoryPressureAndPhysicalCompressorFootprint() {
    XCTAssertEqual(MemoryPressure(systemLevel: 1), .normal)
    XCTAssertEqual(MemoryPressure(systemLevel: 2), .warning)
    XCTAssertEqual(MemoryPressure(systemLevel: 4), .critical)
    XCTAssertEqual(MemoryPressure(systemLevel: nil), .unavailable)
    XCTAssertEqual(MemoryPressure(systemLevel: 99), .unavailable)
    XCTAssertEqual(
      MemoryStatus.usedBytes(
        active: 10, wired: 5, compressor: 3,
        purgeable: 2, pageSize: 4096, total: 1_000_000), 16 * 4096)
    XCTAssertEqual(
      MemoryStatus.usedBytes(
        active: 10, wired: 5, compressor: 3,
        purgeable: 200, pageSize: 4096, total: 1_000_000), 0)
    XCTAssertEqual(
      MemoryStatus.usedBytes(
        active: 100, wired: 500, compressor: 3,
        purgeable: 0, pageSize: 4096, total: 1_000), 1_000)
    // High usage alone is not pressure; these values can coexist on macOS.
    let memory = MemoryStatus(total: 100, used: 99, compressed: 10, swap: 0, pressure: .normal)
    XCTAssertEqual(memory.pressure, .normal)
  }
  func testStorageThresholdsAndInvalidCapacity() {
    let storage = StorageStatus(
      volume: "Data", path: "/System/Volumes/Data",
      total: 100_000_000_000, available: 0)
    XCTAssertEqual(storage?.used, 100_000_000_000)
    XCTAssertEqual(storage?.lowSpace, true)
    XCTAssertEqual(
      StorageStatus(
        volume: "Data", path: "/", total: 1_000_000_000_000,
        available: 49_000_000_000)?.lowSpace, true)
    XCTAssertEqual(
      StorageStatus(
        volume: "Data", path: "/", total: 100_000_000_000,
        available: 10_000_000_000)?.lowSpace, false)
    for (total, free) in [(0, 0), (100, -1), (100, 101)] {
      XCTAssertNil(
        StorageStatus(volume: "Data", path: "/", total: Int64(total), available: Int64(free)))
    }
  }
  func testNetworkRatesResetForSwitchDisconnectCounterResetAndSleep() {
    var rates = NetworkRateSampler()
    func counter(_ interface: String = "en0", _ received: UInt64, _ sent: UInt64, _ time: Double)
      -> NetworkCounter
    {
      NetworkCounter(interface: interface, received: received, sent: sent, time: time)
    }
    XCTAssertNil(rates.sample(counter("en0", 100, 100, 0)))
    XCTAssertEqual(
      rates.sample(counter("en0", 2100, 1100, 2)), NetworkRates(download: 1000, upload: 500))
    XCTAssertEqual(
      rates.sample(counter("en0", 2100, 1100, 4)), NetworkRates(download: 0, upload: 0))
    XCTAssertNil(rates.sample(counter("utun4", 2100, 1100, 6)))
    XCTAssertNil(rates.sample(counter("utun4", 10, 10, 8)))
    XCTAssertNil(rates.sample(counter("utun4", 1000, 1000, 28)))
    XCTAssertNil(rates.sample(nil))
    XCTAssertNil(rates.sample(counter("en0", 2000, 2000, 30)))
    rates.reset()
    XCTAssertNil(rates.sample(counter("en0", 3000, 3000, 32)))
  }
  func testIndependentFailuresStaleValuesAndRecovery() {
    var snapshot = SystemStatusSnapshot()
    XCTAssertEqual(snapshot.battery.state, .loading)
    let now = Date(timeIntervalSince1970: 100)
    var valid = SystemStatusSnapshot()
    valid.battery = ResourceReading(
      value: BatteryStatus(
        percentage: 0, mode: .discharging,
        externalPower: false), state: .ready, sampledAt: now)
    valid.memory = ResourceReading(state: .unavailable)
    valid.network = ResourceReading(
      value: NetworkStatus(interface: nil, connection: "Disconnected"),
      state: .ready, sampledAt: now)
    snapshot.accept(valid)
    XCTAssertEqual(snapshot.battery.value?.percentage, 0)
    XCTAssertEqual(snapshot.memory.state, .unavailable)
    XCTAssertEqual(snapshot.network.value?.connected, false)
    var failed = valid
    failed.battery = ResourceReading(state: .error, message: "probe failed")
    snapshot.accept(failed)
    XCTAssertEqual(snapshot.battery.state, .stale)
    XCTAssertEqual(snapshot.battery.sampledAt, now)
    XCTAssertEqual(snapshot.battery.value?.percentage, 0)
    XCTAssertEqual(snapshot.battery.message, "probe failed")
    XCTAssertEqual(snapshot.network.state, .ready)
    snapshot.accept(valid)
    XCTAssertEqual(snapshot.battery.state, .ready)
    XCTAssertTrue(snapshot.battery.message.isEmpty)
    snapshot.markStale()
    XCTAssertEqual(snapshot.network.state, .stale)
  }
  func testSamplingPolicyRequiresOpenAndAllSuspensionsCleared() {
    var policy = ResourceMonitoringPolicy()
    XCTAssertFalse(policy.shouldSample)
    policy.open = true
    XCTAssertTrue(policy.shouldSample)
    policy.suspensions = ["sleep", "lock"]
    XCTAssertFalse(policy.shouldSample)
    policy.suspensions.remove("sleep")
    XCTAssertFalse(policy.shouldSample)
    policy.suspensions.remove("lock")
    XCTAssertTrue(policy.shouldSample)
    policy.open = false
    XCTAssertFalse(policy.shouldSample)
  }
  func testBilingualLauncherResourceAliases() {
    for query in [
      "System Status", "Состояние системы", "battery", "батарея", "memory", "память",
      "storage", "диск", "network", "сеть", "RAM", "Wi-Fi", "VPN",
    ] {
      XCTAssertEqual(
        LauncherSearch.apps(LauncherSearch.builtinApps, query: query).first?.id,
        "builtin:system-status", query)
    }
  }
}
