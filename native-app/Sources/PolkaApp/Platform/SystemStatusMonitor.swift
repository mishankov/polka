import AppKit
import Combine
import Darwin
import IOKit.ps
import PolkaCore
import SystemConfiguration

/// No commands, shell processes, network requests, SSIDs, or permissions are needed.
/// Serial actor work keeps probes off the UI thread and prevents overlapping samples.
actor SystemResourceProbe {
  private var rates = NetworkRateSampler()
  private var session = -1
  private var cachedStorage: ResourceReading<StorageStatus>?
  func sample(session: Int) -> SystemStatusSnapshot {
    if self.session != session {
      rates.reset()
      cachedStorage = nil
      self.session = session
    }
    let now = Date()
    var result = SystemStatusSnapshot()
    result.battery = Self.read(now) { try Self.battery() }
    result.memory = Self.read(now) { try Self.memory() }
    // Capacity probes run at most every 15 seconds; other values update every two.
    if cachedStorage?.sampledAt.map({ now.timeIntervalSince($0) < 15 }) != true {
      cachedStorage = Self.read(now) { try Self.storage() }
    }
    result.storage = cachedStorage!
    result.network = Self.read(now) { try network() }
    if result.network.state != .ready { rates.reset() }
    return result
  }
  private enum ProbeError: Error { case unavailable, failed }
  private static func read<T>(_ now: Date, _ operation: () throws -> T) -> ResourceReading<T> {
    do {
      return ResourceReading(value: try operation(), state: .ready, sampledAt: now)
    } catch ProbeError.unavailable {
      return ResourceReading(state: .unavailable, message: "Not available from macOS")
    } catch { return ResourceReading(state: .error, message: "Could not read this resource") }
  }
  private static func battery() throws -> BatteryStatus {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { throw ProbeError.failed }
    var descriptions: [[String: Any]] = []
    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
          as? [String: Any]
      else { throw ProbeError.failed }
      descriptions.append(description)
    }
    guard
      let battery = descriptions.first(where: {
        ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
      })
    else { return BatteryStatus(percentage: nil, mode: .noBattery, externalPower: true) }
    guard let current = battery[kIOPSCurrentCapacityKey] as? Int,
      let maximum = battery[kIOPSMaxCapacityKey] as? Int,
      let charging = battery[kIOPSIsChargingKey] as? Bool,
      let power = battery[kIOPSPowerSourceStateKey] as? String,
      [kIOPSACPowerValue, kIOPSBatteryPowerValue].contains(power)
    else { throw ProbeError.unavailable }
    let external = power == kIOPSACPowerValue
    let minutes = battery[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
    guard
      let result = BatteryStatus.normalize(
        current: current, maximum: maximum, charging: charging,
        charged: battery[kIOPSIsChargedKey] as? Bool ?? (current == maximum && external),
        externalPower: external, minutes: minutes)
    else { throw ProbeError.unavailable }
    return result
  }
  private static func sysctlValue<T>(_ name: String, into value: inout T) -> Bool {
    var size = MemoryLayout<T>.size
    return withUnsafeMutableBytes(of: &value) {
      sysctlbyname(name, $0.baseAddress, &size, nil, 0) == 0 && size == MemoryLayout<T>.size
    }
  }
  private static func memory() throws -> MemoryStatus {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    let status = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { throw ProbeError.failed }
    var level: Int32 = 0
    let pressure = MemoryPressure(
      systemLevel: sysctlValue("kern.memorystatus_vm_pressure_level", into: &level) ? level : nil)
    var swap = xsw_usage()
    let hasSwap = sysctlValue("vm.swapusage", into: &swap)
    let total = ProcessInfo.processInfo.physicalMemory
    let page = UInt64(vm_page_size)
    return MemoryStatus(
      total: total,
      used: MemoryStatus.usedBytes(
        active: UInt64(stats.active_count), wired: UInt64(stats.wire_count),
        compressor: UInt64(stats.compressor_page_count), purgeable: UInt64(stats.purgeable_count),
        pageSize: page, total: total),
      compressed: UInt64(stats.compressor_page_count) * page,
      swap: hasSwap ? swap.xsu_used : nil, pressure: pressure)
  }
  private static func storage() throws -> StorageStatus {
    // The writable startup Data volume shares APFS capacity with the system volume.
    // Read it once; never add their capacities or count purgeable bytes as already free.
    let path = "/System/Volumes/Data"
    let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [
      .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ])
    guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity,
      let result = StorageStatus(
        volume: values.volumeName ?? "Data", path: path,
        total: Int64(total), available: Int64(free))
    else { throw ProbeError.unavailable }
    return result
  }
  private func network() throws -> NetworkStatus {
    guard let store = SCDynamicStoreCreate(nil, "Polka System Status" as CFString, nil, nil)
    else { throw ProbeError.failed }
    let interfaces = ["IPv4", "IPv6"].compactMap { family -> String? in
      let value =
        SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString)
        as? [String: Any]
      return value?[kSCDynamicStorePropNetPrimaryInterface as String] as? String
    }
    // Prefer a tunnel when macOS exposes it as a primary route. Counting exactly
    // one interface avoids summing VPN traffic again on its physical transport.
    guard
      let interface = interfaces.first(where: { $0.hasPrefix("utun") || $0.hasPrefix("ppp") })
        ?? interfaces.first
    else {
      rates.reset()
      return NetworkStatus(interface: nil, connection: "Disconnected")
    }
    let preferences = SCPreferencesCreate(nil, "Polka" as CFString, nil)
    let services = preferences.flatMap { SCNetworkServiceCopyAll($0) as? [SCNetworkService] } ?? []
    let type = services.compactMap { SCNetworkServiceGetInterface($0) }.first {
      (SCNetworkInterfaceGetBSDName($0) as String?) == interface
    }.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
    let connection =
      interface.hasPrefix("utun") || interface.hasPrefix("ppp")
      ? "VPN"
      : type == (kSCNetworkInterfaceTypeIEEE80211 as String)
        ? "Wi-Fi"
        : type == (kSCNetworkInterfaceTypeEthernet as String) ? "Ethernet" : "Network"
    let counter = try Self.counter(interface)
    return NetworkStatus(interface: interface, connection: connection, rates: rates.sample(counter))
  }
  private static func counter(_ interface: String) throws -> NetworkCounter {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0, size < 4_000_000
    else { throw ProbeError.failed }
    // malloc provides alignment for the route headers. Bound every record before reading it.
    guard let buffer = malloc(size) else { throw ProbeError.failed }
    defer { free(buffer) }
    guard sysctl(&mib, u_int(mib.count), buffer, &size, nil, 0) == 0 else {
      throw ProbeError.failed
    }
    var offset = 0
    // Route records share only the four-byte length/version/type prefix;
    // RTM_NEWADDR records are shorter than an interface header.
    while offset + 4 <= size {
      let pointer = buffer.advanced(by: offset)
      let length = Int(pointer.loadUnaligned(as: UInt16.self))
      let type = pointer.advanced(by: 3).load(as: UInt8.self)
      guard length >= 4, offset + length <= size else {
        throw ProbeError.failed
      }
      if type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
        let info = pointer.loadUnaligned(as: if_msghdr2.self)
        if UInt32(info.ifm_index) == if_nametoindex(interface) {
          return NetworkCounter(
            interface: interface, received: info.ifm_data.ifi_ibytes,
            sent: info.ifm_data.ifi_obytes, time: ProcessInfo.processInfo.systemUptime)
        }
      }
      offset += length
    }
    throw ProbeError.unavailable
  }
}

@MainActor final class SystemStatusMonitor {
  private let model: NativeUIModel
  private let probe = SystemResourceProbe()
  private var observation: AnyCancellable?
  private var task: Task<Void, Never>?
  private var generation = 0
  private(set) var policy = ResourceMonitoringPolicy()
  private let fixture: Bool
  private let sample: (Int) async -> SystemStatusSnapshot
  private let interval: UInt64
  private(set) var sampleCount = 0
  init(
    model: NativeUIModel, fixture: Bool,
    interval: UInt64 = 2_000_000_000,
    sample: ((Int) async -> SystemStatusSnapshot)? = nil
  ) {
    self.model = model
    self.fixture = fixture
    self.interval = interval
    let probe = self.probe
    self.sample = sample ?? { session in await probe.sample(session: session) }
    observation = model.$visible.combineLatest(model.$destination).map {
      $0 && $1 == "system-status"
    }
    .removeDuplicates().sink { [weak self] open in self?.setOpen(open) }
  }
  func setOpen(_ open: Bool) {
    policy.open = open
    reconcile()
  }
  func suspend(_ reason: String, suspended: Bool) {
    if suspended { policy.suspensions.insert(reason) } else { policy.suspensions.remove(reason) }
    reconcile()
  }
  private func reconcile() {
    guard policy.shouldSample else {
      generation += 1
      task?.cancel()
      task = nil
      model.systemStatus.markStale()
      return
    }
    guard task == nil, !fixture else { return }
    model.systemStatus.activity.reset()
    generation += 1
    let session = generation
    let sample = self.sample
    let interval = self.interval
    task = Task { [weak self] in
      while !Task.isCancelled {
        let snapshot = await sample(session)
        guard !Task.isCancelled, let self, self.generation == session else { return }
        self.model.systemStatus.accept(snapshot)
        self.sampleCount += 1
        do { try await Task.sleep(nanoseconds: interval) } catch { return }
      }
    }
  }
  func stop() {
    observation = nil
    policy.open = false
    reconcile()
  }
}
