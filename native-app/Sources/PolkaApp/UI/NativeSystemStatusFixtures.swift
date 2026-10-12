import Foundation
import PolkaCore

/// Synthetic readings used by the isolated desktop harness; never system-changing commands.
enum NativeSystemStatusFixtures {
  static func snapshot(_ state: String) -> SystemStatusSnapshot {
    let now = Date()
    var result = SystemStatusSnapshot()
    result.battery = ResourceReading(
      value: BatteryStatus(
        percentage: 76, mode: .discharging,
        externalPower: false, estimatedMinutes: 185), state: .ready, sampledAt: now)
    result.memory = ResourceReading(
      value: MemoryStatus(
        total: 16 * 1_073_741_824,
        used: 10 * 1_073_741_824, compressed: 1_073_741_824, swap: 0, pressure: .normal),
      state: .ready, sampledAt: now)
    result.storage = ResourceReading(
      value: StorageStatus(
        volume: "Macintosh HD — Data",
        path: "/System/Volumes/Data", total: 500_000_000_000, available: 180_000_000_000)!,
      state: .ready, sampledAt: now)
    result.network = ResourceReading(
      value: NetworkStatus(
        interface: "en0", connection: "Wi-Fi",
        rates: NetworkRates(download: 1_400_000, upload: 128_000)), state: .ready, sampledAt: now)
    if state == "warning" {
      result.battery.value = BatteryStatus(
        percentage: 7, mode: .discharging, externalPower: false, estimatedMinutes: 12)
      result.memory.value?.pressure = .critical
      result.memory.value?.swap = 4 * 1_073_741_824
      result.storage.value = StorageStatus(
        volume: "Macintosh HD — Data", path: "/System/Volumes/Data",
        total: 500_000_000_000, available: 2_000_000_000)
      result.network.value = NetworkStatus(interface: nil, connection: "Disconnected")
    } else if state == "unavailable" {
      result.battery.value = BatteryStatus(percentage: nil, mode: .noBattery, externalPower: true)
      result.memory = ResourceReading(state: .unavailable, message: "Not available from macOS")
      result.storage.state = .stale
      result.storage.sampledAt = now.addingTimeInterval(-90)
      result.storage.message = "Could not read this resource"
      result.network.value = NetworkStatus(interface: "utun4", connection: "VPN")
    } else if state == "zero-traffic" {
      result.network.value?.rates = NetworkRates(download: 0, upload: 0)
    }
    let base = result
    let end = ProcessInfo.processInfo.systemUptime
    let start = max(0, end - SystemActivityHistory.duration)
    for index in 0..<SystemActivityHistory.maximumSamples {
      var sample = base
      if index < SystemActivityHistory.maximumSamples - 1 {
        if let memory = sample.memory.value {
          let progress = Double(index) / 30
          sample.memory.value?.used = UInt64(
            Double(memory.used) * (0.94 + progress * 0.06 + sin(Double(index) * 0.9) * 0.008))
        }
        if state != "zero-traffic", let rates = sample.network.value?.rates {
          sample.network.value?.rates = NetworkRates(
            download: rates.download * (0.7 + abs(sin(Double(index) * 1.3)) * 0.85),
            upload: rates.upload * (0.4 + abs(sin(Double(index) * 0.8)) * 0.8))
        }
      }
      result.activity.record(sample, at: start + (end - start) * Double(index) / 30)
    }
    return result
  }
}
