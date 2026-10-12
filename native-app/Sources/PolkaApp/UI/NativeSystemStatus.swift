import PolkaCore
import SwiftUI

struct NativeSystemStatusView: View {
  @ObservedObject var model: NativeUIModel
  var body: some View {
    VStack(spacing: 0) {
      NativeBuiltinHeader(model: model, title: localized("System Status")) { EmptyView() }
      Divider()
      ScrollView {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          batteryCard
          memoryCard
          storageCard
          networkCard
        }.padding(14)
      }
    }.accessibilityIdentifier("system-status-overview")
  }
  private var batteryCard: some View {
    card("Battery", symbol: "battery.75percent", reading: model.systemStatus.battery) {
      battery in
      metric(battery.percentage.map { "\($0)%" } ?? localized("No battery"))
      status(
        batteryLabel(battery),
        warning: battery.mode == .discharging && (battery.percentage ?? 100) <= 10)
      detail(localized(battery.externalPower ? "Power adapter" : "Battery power"))
      if let minutes = battery.estimatedMinutes {
        detail(
          localized(
            battery.mode == .charging ? "About {0} until charged" : "About {0} remaining",
            duration(minutes)))
      }
      if model.systemStatus.battery.state == .ready, let percentage = battery.percentage {
        Spacer(minLength: 0)
        NativeResourceMeter(
          fraction: Double(percentage) / 100, label: localized("Charge"),
          warning: battery.mode == .discharging && percentage <= 10
        )
        .accessibilityIdentifier("system-status-battery-meter")
      }
    }
  }
  private var memoryCard: some View {
    card("Memory", symbol: "memorychip", reading: model.systemStatus.memory) { memory in
      metric(localized("{0} used", bytes(memory.used)))
      status(
        pressureLabel(memory.pressure),
        warning: memory.pressure == .warning || memory.pressure == .critical)
      detail(localized("{0} total", bytes(memory.total)))
      detail(localized("Compressed: {0}", bytes(memory.compressed)))
      detail(
        localized("Swap: {0}", memory.swap.map { bytes($0) } ?? localized("Unavailable")))
      if model.systemStatus.memory.state == .ready {
        Spacer(minLength: 0)
        memoryActivity(memory).accessibilityIdentifier("system-status-memory-activity")
      }
    }
  }
  private var storageCard: some View {
    card("Storage", symbol: "internaldrive", reading: model.systemStatus.storage) { storage in
      metric(localized("{0} available", bytes(UInt64(storage.available), storage: true)))
      status(
        localized(storage.lowSpace ? "Low space — free up storage" : "Enough space"),
        warning: storage.lowSpace)
      detail(
        localized(
          "{0} used of {1}", bytes(UInt64(storage.used), storage: true),
          bytes(UInt64(storage.total), storage: true)))
      detail(storage.volume + " · " + localized("Startup Data volume"))
        .help(storage.path)
      if model.systemStatus.storage.state == .ready {
        Spacer(minLength: 0)
        NativeResourceMeter(
          fraction: Double(storage.available) / Double(storage.total),
          label: localized("Available"), warning: storage.lowSpace
        )
        .accessibilityIdentifier("system-status-storage-meter")
      }
    }
  }
  private var networkCard: some View {
    card("Network", symbol: "network", reading: model.systemStatus.network) { network in
      metric(localized(network.connected ? "Connected" : "Disconnected"))
      if let interface = network.interface {
        detail(localized(network.connection) + " · " + interface)
        if let rates = network.rates {
          HStack(spacing: 5) {
            NativeActivityLineKey()
            detail("↓ " + localized("Download") + "  " + rate(rates.download))
          }
          HStack(spacing: 5) {
            NativeActivityLineKey(upload: true)
            detail("↑ " + localized("Upload") + "  " + rate(rates.upload))
          }
        } else {
          detail(localized("Measuring traffic…"))
        }
      } else {
        detail(localized("No active network connection"))
      }
      if model.systemStatus.network.state == .ready, network.connected, network.rates != nil {
        Spacer(minLength: 0)
        networkActivity.accessibilityIdentifier("system-status-network-activity")
      }
    }
  }
  private func card<T, Content: View>(
    _ title: String, symbol: String,
    reading: ResourceReading<T>, @ViewBuilder content: (T) -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(localized(title), systemImage: symbol).font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
      if let value = reading.value {
        content(value)
        if reading.state == .stale {
          Text(
            localized(
              "Stale · last read {0}",
              reading.sampledAt?.formatted(date: .omitted, time: .standard) ?? "—")
          )
          .font(.system(size: 11)).foregroundStyle(.orange)
          if !reading.message.isEmpty { detail(localized(reading.message)) }
        }
      } else {
        metric(
          localized(
            reading.state == .loading
              ? "Loading…" : reading.state == .error ? "Reading failed" : "Unavailable"))
        if !reading.message.isEmpty { detail(localized(reading.message)) }
      }
    }.frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading).padding(12)
      .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("system-status-" + title.lowercased())
  }
  @ViewBuilder private func memoryActivity(_ memory: MemoryStatus) -> some View {
    let activity = model.systemStatus.activity
    if activity.memory.count >= 2, let now = activity.time {
      let domain = activity.memoryDomain(total: memory.total)
      NativeResourceActivityChart(
        lines: [
          NativeActivityLine(
            points: activity.memory.map {
              NativeActivityPoint(time: $0.time, value: $0.used)
            })
        ], domain: domain, now: now,
        scaleLabel: bytes(UInt64(domain.lowerBound)) + "–" + bytes(UInt64(domain.upperBound)),
        label: localized("Recent memory usage"))
    } else {
      collectingActivity
    }
  }
  @ViewBuilder private var networkActivity: some View {
    let activity = model.systemStatus.activity
    if activity.network.count >= 2, let now = activity.time {
      NativeResourceActivityChart(
        lines: [
          NativeActivityLine(
            points: activity.network.map {
              NativeActivityPoint(time: $0.time, value: $0.download)
            }),
          NativeActivityLine(
            points: activity.network.map {
              NativeActivityPoint(time: $0.time, value: $0.upload)
            }, upload: true),
        ], domain: 0...activity.networkMaximum, now: now,
        scaleLabel: "0–" + rate(activity.networkMaximum), label: localized("Recent network traffic")
      )
    } else {
      collectingActivity
    }
  }
  private var collectingActivity: some View {
    Text(localized("Collecting recent activity…")).font(.system(size: 11)).foregroundStyle(
      .secondary
    )
    .frame(maxWidth: .infinity, minHeight: 47, alignment: .bottomLeading)
  }
  private func metric(_ value: String) -> some View {
    Text(value).font(.system(size: 18, weight: .medium)).monospacedDigit()
      .fixedSize(horizontal: false, vertical: true)
  }
  private func status(_ value: String, warning: Bool = false) -> some View {
    Text(value).font(.system(size: 12, weight: .medium))
      .foregroundStyle(warning ? Color.orange : Color.primary)
      .fixedSize(horizontal: false, vertical: true)
  }
  private func detail(_ value: String) -> some View {
    Text(value).font(.system(size: 11)).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
  private func bytes(_ value: UInt64, storage: Bool = false) -> String {
    Int64(clamping: value).formatted(
      .byteCount(style: storage ? .file : .memory, spellsOutZero: false)
        .locale(model.settings.language.locale))
  }
  private func rate(_ value: Double) -> String {
    let units = [localized("B/s"), localized("KB/s"), localized("MB/s"), localized("GB/s")]
    var amount = max(0, value)
    var unit = 0
    while amount >= 1000, unit < units.count - 1 {
      amount /= 1000
      unit += 1
    }
    return amount.formatted(
      .number.locale(model.settings.language.locale).precision(.fractionLength(0...1))) + " "
      + units[unit]
  }
  private func duration(_ minutes: Int) -> String {
    minutes < 60
      ? localized("{0} min", String(minutes))
      : localized("{0} h {1} min", String(minutes / 60), String(minutes % 60))
  }
  private func batteryLabel(_ value: BatteryStatus) -> String {
    switch value.mode {
    case .noBattery: return localized("This Mac has no built-in battery")
    case .charging: return localized("Charging")
    case .discharging:
      return localized(
        (value.percentage ?? 100) <= 10 ? "Low battery · discharging" : "Discharging")
    case .full: return localized("Fully charged")
    case .pluggedIn: return localized("Plugged in · not charging")
    }
  }
  private func pressureLabel(_ value: MemoryPressure) -> String {
    switch value {
    case .normal: return localized("Memory pressure: normal")
    case .warning: return localized("High memory pressure")
    case .critical: return localized("Critical memory pressure")
    case .unavailable: return localized("Memory pressure unavailable")
    }
  }
}
