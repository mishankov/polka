import Foundation

public enum ResourceState: String, Sendable { case loading, ready, unavailable, stale, error }

/// A failed refresh retains the last reading, explicitly marked stale.
public struct ResourceReading<Value: Equatable & Sendable>: Equatable, Sendable {
  public var value: Value?
  public var state: ResourceState
  public var sampledAt: Date?
  public var message: String
  public init(
    value: Value? = nil, state: ResourceState = .loading, sampledAt: Date? = nil,
    message: String = ""
  ) {
    self.value = value
    self.state = state
    self.sampledAt = sampledAt
    self.message = message
  }
  public mutating func accept(_ next: Self) {
    if next.state != .ready, let value, let sampledAt {
      self = Self(value: value, state: .stale, sampledAt: sampledAt, message: next.message)
    } else {
      self = next
    }
  }
  public mutating func markStale() {
    if value != nil { state = .stale }
  }
}

public struct BatteryStatus: Equatable, Sendable {
  public enum Mode: String, Sendable { case noBattery, charging, discharging, full, pluggedIn }
  public var percentage: Int?
  public var mode: Mode
  public var externalPower: Bool
  public var estimatedMinutes: Int?
  public init(percentage: Int?, mode: Mode, externalPower: Bool, estimatedMinutes: Int? = nil) {
    self.percentage = percentage
    self.mode = mode
    self.externalPower = externalPower
    self.estimatedMinutes = estimatedMinutes
  }
  public static func normalize(
    current: Int, maximum: Int, charging: Bool, charged: Bool,
    externalPower: Bool, minutes: Int?
  ) -> Self? {
    guard maximum > 0, current >= 0, current <= maximum else { return nil }
    let percent = Int((Double(current) / Double(maximum) * 100).rounded())
    let mode: Mode =
      charging ? .charging : charged ? .full : externalPower ? .pluggedIn : .discharging
    return Self(
      percentage: percent, mode: mode, externalPower: externalPower,
      estimatedMinutes: mode == .charging || mode == .discharging
        ? minutes.flatMap { $0 > 0 ? $0 : nil } : nil)
  }
}

public enum MemoryPressure: String, Sendable {
  case normal, warning, critical, unavailable
  public init(systemLevel: Int32?) {
    switch systemLevel {
    case 1: self = .normal
    case 2: self = .warning
    case 4: self = .critical
    default: self = .unavailable
    }
  }
}
public struct MemoryStatus: Equatable, Sendable {
  public var total: UInt64
  public var used: UInt64
  public var compressed: UInt64
  public var swap: UInt64?
  public var pressure: MemoryPressure
  public init(
    total: UInt64, used: UInt64, compressed: UInt64, swap: UInt64?, pressure: MemoryPressure
  ) {
    self.total = total
    self.used = min(total, used)
    self.compressed = compressed
    self.swap = swap
    self.pressure = pressure
  }
  public static func usedBytes(
    active: UInt64, wired: UInt64, compressor: UInt64,
    purgeable: UInt64, pageSize: UInt64, total: UInt64
  ) -> UInt64 {
    // Compressor pages are the physical footprint, not the original uncompressed pages.
    let pages = Double(active) + Double(wired) + Double(compressor) - Double(purgeable)
    return UInt64(min(Double(total), max(0, pages) * Double(pageSize)))
  }
}

public struct StorageStatus: Equatable, Sendable {
  public var volume: String
  public var path: String
  public var total: Int64
  public var available: Int64
  public var used: Int64 { total - available }
  public var lowSpace: Bool { available < max(5_000_000_000, total / 20) }
  public init?(volume: String, path: String, total: Int64, available: Int64) {
    guard total > 0, available >= 0, available <= total else { return nil }
    self.volume = volume
    self.path = path
    self.total = total
    self.available = available
  }
}

public struct NetworkCounter: Equatable, Sendable {
  public var interface: String
  public var received: UInt64
  public var sent: UInt64
  public var time: Double
  public init(interface: String, received: UInt64, sent: UInt64, time: Double) {
    self.interface = interface
    self.received = received
    self.sent = sent
    self.time = time
  }
}
public struct NetworkRates: Equatable, Sendable {
  public var download: Double
  public var upload: Double
  public init(download: Double, upload: Double) {
    self.download = download
    self.upload = upload
  }
}
public struct NetworkRateSampler: Sendable {
  public private(set) var previous: NetworkCounter?
  public init() {}
  public mutating func reset() { previous = nil }
  public mutating func sample(_ counter: NetworkCounter?) -> NetworkRates? {
    defer { previous = counter }
    guard let counter, let previous, counter.interface == previous.interface,
      counter.received >= previous.received, counter.sent >= previous.sent
    else { return nil }
    let duration = counter.time - previous.time
    guard duration >= 0.25, duration <= 10, duration.isFinite else { return nil }
    return NetworkRates(
      download: Double(counter.received - previous.received) / duration,
      upload: Double(counter.sent - previous.sent) / duration)
  }
}
public struct NetworkStatus: Equatable, Sendable {
  public var interface: String?
  public var connection: String
  public var rates: NetworkRates?
  public var connected: Bool { interface != nil }
  public init(interface: String?, connection: String, rates: NetworkRates? = nil) {
    self.interface = interface
    self.connection = connection
    self.rates = rates
  }
}

public struct SystemStatusSnapshot: Equatable, Sendable {
  public var battery = ResourceReading<BatteryStatus>()
  public var memory = ResourceReading<MemoryStatus>()
  public var storage = ResourceReading<StorageStatus>()
  public var network = ResourceReading<NetworkStatus>()
  public var activity = SystemActivityHistory()
  public init() {}
  public mutating func accept(_ next: Self, time: Double = ProcessInfo.processInfo.systemUptime) {
    battery.accept(next.battery)
    memory.accept(next.memory)
    storage.accept(next.storage)
    network.accept(next.network)
    activity.record(next, at: time)
  }
  public mutating func markStale() {
    battery.markStale()
    memory.markStale()
    storage.markStale()
    network.markStale()
    // Previous rates never describe a new session or a resumed interface.
    network.value?.rates = nil
    activity.reset()
  }
}

public struct MemoryActivitySample: Equatable, Sendable {
  public var time: Double
  public var used: Double
}
public struct NetworkActivitySample: Equatable, Sendable {
  public var time: Double
  public var download: Double
  public var upload: Double
}

/// Only the current viewing session is retained: a minute, at most 31 samples.
/// Failed probes and interface changes start a new line rather than bridging gaps.
public struct SystemActivityHistory: Equatable, Sendable {
  public static let duration = 60.0
  public static let maximumSamples = 31
  public private(set) var memory: [MemoryActivitySample] = []
  public private(set) var network: [NetworkActivitySample] = []
  public private(set) var time: Double?
  private var memoryTotal: UInt64?
  private var interface: String?
  public init() {}
  public mutating func reset() { self = Self() }
  public mutating func record(_ snapshot: SystemStatusSnapshot, at now: Double) {
    guard now.isFinite, now >= 0 else { return }
    if let time, now < time { reset() }
    time = now
    if snapshot.memory.state == .ready, let value = snapshot.memory.value,
      value.total > 0, value.used <= value.total
    {
      if memoryTotal != value.total { memory.removeAll(keepingCapacity: true) }
      memoryTotal = value.total
      if memory.last?.time == now { memory.removeLast() }
      memory.append(MemoryActivitySample(time: now, used: Double(value.used)))
    } else {
      memory.removeAll(keepingCapacity: true)
      memoryTotal = nil
    }
    if snapshot.network.state == .ready, let value = snapshot.network.value,
      let currentInterface = value.interface
    {
      if interface != currentInterface { network.removeAll(keepingCapacity: true) }
      interface = currentInterface
      if let rates = value.rates, rates.download.isFinite, rates.upload.isFinite,
        rates.download >= 0, rates.upload >= 0
      {
        if network.last?.time == now { network.removeLast() }
        network.append(
          NetworkActivitySample(time: now, download: rates.download, upload: rates.upload))
      } else {
        network.removeAll(keepingCapacity: true)
      }
    } else {
      network.removeAll(keepingCapacity: true)
      interface = nil
    }
    memory.removeAll { $0.time < now - Self.duration }
    network.removeAll { $0.time < now - Self.duration }
    if memory.count > Self.maximumSamples { memory.removeFirst(memory.count - Self.maximumSamples) }
    if network.count > Self.maximumSamples {
      network.removeFirst(network.count - Self.maximumSamples)
    }
  }

  /// A minimum vertical span avoids magnifying small RAM fluctuations.
  public func memoryDomain(total: UInt64) -> ClosedRange<Double> {
    let capacity = max(1, Double(total))
    let low = memory.map(\.used).min() ?? 0
    let high = memory.map(\.used).max() ?? 0
    let span = min(capacity, max(268_435_456, capacity / 16, (high - low) * 1.2))
    let lower = max(0, min(capacity - span, (low + high - span) / 2))
    return lower...min(capacity, max(lower + span, high))
  }
  /// Both traffic lines use the same scale; zero traffic stays a valid flat line.
  public var networkMaximum: Double {
    max(1_000, (network.map { max($0.download, $0.upload) }.max() ?? 0) * 1.1)
  }
}

/// Shared by the sampler and tests; nested sleep/lock reasons must resume independently.
public struct ResourceMonitoringPolicy: Equatable, Sendable {
  public var open = false
  public var suspensions = Set<String>()
  public var shouldSample: Bool { open && suspensions.isEmpty }
  public init() {}
}
