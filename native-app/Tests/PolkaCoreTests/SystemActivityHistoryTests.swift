import Foundation
import PolkaCore
import XCTest

final class SystemActivityHistoryTests: XCTestCase {
  private func sample(
    used: UInt64 = 800, total: UInt64 = 1600, interface: String? = "en0",
    download: Double = 100, upload: Double = 10
  ) -> SystemStatusSnapshot {
    var snapshot = SystemStatusSnapshot()
    snapshot.memory = ResourceReading(
      value: MemoryStatus(
        total: total, used: used,
        compressed: 0, swap: nil, pressure: .normal), state: .ready)
    snapshot.network = ResourceReading(
      value: NetworkStatus(
        interface: interface,
        connection: "Wi-Fi", rates: NetworkRates(download: download, upload: upload)), state: .ready
    )
    return snapshot
  }
  func testMinuteAndSampleCountRemainBounded() {
    var history = SystemActivityHistory()
    for time in stride(from: 0.0, through: 200, by: 2) {
      history.record(sample(), at: time)
    }
    XCTAssertEqual(history.memory.count, 31)
    XCTAssertEqual(history.network.count, 31)
    XCTAssertEqual(history.memory.first?.time, 140)
    XCTAssertEqual(history.network.last?.time, 200)
    for index in 0..<100 { history.record(sample(), at: 201 + Double(index) / 100) }
    XCTAssertEqual(history.memory.count, 31)
    XCTAssertEqual(history.network.count, 31)
    history.record(sample(), at: 300)
    XCTAssertEqual(history.memory.count, 1)
    XCTAssertEqual(history.network.count, 1)
  }
  func testProbeFailureAndInterfaceSwitchResetOnlyTheAffectedLine() {
    var history = SystemActivityHistory()
    history.record(sample(), at: 0)
    history.record(sample(), at: 2)
    history.record(sample(interface: "utun4"), at: 4)
    XCTAssertEqual(history.memory.count, 3)
    XCTAssertEqual(history.network.count, 1)
    var failure = sample(interface: "utun4")
    failure.memory = ResourceReading(state: .error)
    history.record(failure, at: 6)
    XCTAssertTrue(history.memory.isEmpty)
    XCTAssertEqual(history.network.count, 2)
    failure.memory = sample().memory
    failure.network = ResourceReading(state: .unavailable)
    history.record(failure, at: 8)
    XCTAssertEqual(history.memory.count, 1)
    XCTAssertTrue(history.network.isEmpty)
    history.record(sample(interface: nil), at: 10)
    XCTAssertTrue(history.network.isEmpty)
    var warmup = sample()
    warmup.network.value?.rates = nil
    history.record(warmup, at: 12)
    XCTAssertTrue(history.network.isEmpty)
    history.record(sample(), at: 14)
    XCTAssertEqual(history.network.count, 1)
  }
  func testZeroRatesAndFlatMemoryHaveUsefulSharedDomains() {
    var history = SystemActivityHistory()
    for time in [0.0, 2, 4] {
      history.record(sample(used: 0, download: 0, upload: 0), at: time)
    }
    XCTAssertEqual(history.network.map(\.download), [0, 0, 0])
    XCTAssertEqual(history.networkMaximum, 1000)
    let emptyRAM = history.memoryDomain(total: 1600)
    XCTAssertEqual(emptyRAM.lowerBound, 0)
    XCTAssertGreaterThan(emptyRAM.upperBound, 0)
    history.reset()
    let total: UInt64 = 32 * 1_073_741_824
    let used: UInt64 = 13 * 1_073_741_824
    history.record(sample(used: used, total: total, download: 100, upload: 800), at: 10)
    history.record(sample(used: used + 1024, total: total, download: 0, upload: 900), at: 12)
    let domain = history.memoryDomain(total: total)
    XCTAssertTrue(domain.contains(Double(used)))
    XCTAssertTrue(domain.contains(Double(used + 1024)))
    XCTAssertGreaterThanOrEqual(domain.upperBound - domain.lowerBound, Double(total) / 16)
    XCTAssertGreaterThan(history.networkMaximum, 900)
  }
  func testInvalidSamplesDuplicateTimesAndSessionReset() {
    var history = SystemActivityHistory()
    history.record(sample(), at: 10)
    history.record(sample(used: 900), at: 10)
    XCTAssertEqual(history.memory.count, 1)
    XCTAssertEqual(history.memory.last?.used, 900)
    history.record(sample(), at: .nan)
    history.record(sample(), at: .infinity)
    history.record(sample(), at: -1)
    XCTAssertEqual(history.time, 10)
    history.record(sample(download: .nan), at: 12)
    XCTAssertTrue(history.network.isEmpty)
    history.record(sample(upload: -1), at: 14)
    XCTAssertTrue(history.network.isEmpty)
    history.record(sample(total: 0), at: 16)
    XCTAssertTrue(history.memory.isEmpty)
    history.record(sample(), at: 18)
    history.record(sample(total: 3200), at: 20)
    XCTAssertEqual(history.memory.count, 1)
    history.record(sample(), at: 2)
    XCTAssertEqual(history.memory.count, 1)
    XCTAssertEqual(history.network.count, 1)
    history.reset()
    XCTAssertTrue(history.memory.isEmpty)
    XCTAssertTrue(history.network.isEmpty)
    XCTAssertNil(history.time)
    var snapshot = SystemStatusSnapshot()
    snapshot.accept(sample(), time: 0)
    snapshot.accept(sample(), time: 2)
    XCTAssertEqual(snapshot.activity.memory.count, 2)
    snapshot.markStale()
    XCTAssertTrue(snapshot.activity.memory.isEmpty)
    XCTAssertTrue(snapshot.activity.network.isEmpty)
  }
}
