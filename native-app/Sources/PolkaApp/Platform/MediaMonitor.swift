import AppKit
import PolkaCore
import SwiftUI

@MainActor final class NativeMediaMonitor {
  private var timer: Timer?
  private var polling = false
  private var epoch = 0
  private var overlays: [String: NSPanel] = [:]
  private var screenObserver: NSObjectProtocol?
  private var lastState: NativeMediaPresentation?
  private var preferences: [String: Bool] = ["cameraEnabled": true, "microphoneEnabled": true]
  private let settings: SettingsStore
  private let model: NativeUIModel
  private let fixture: Bool
  private var suspended = Set<String>()
  init(settings: SettingsStore, model: NativeUIModel, fixture: Bool) {
    self.settings = settings
    self.model = model
    self.fixture = fixture
    let fallback = (try? settings.get(key: "mediaIndicatorEnabled")) as? Bool != false
    let tracking = (try? settings.get(key: "mediaIndicatorTracking")) as? [String: Bool] ?? [:]
    preferences = [
      "cameraEnabled": tracking["cameraEnabled"] ?? fallback,
      "microphoneEnabled": tracking["microphoneEnabled"] ?? fallback,
    ]
    publish()
    restart()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshGeometry() }
    }
  }
  func set(_ device: String, enabled: Bool) throws {
    guard ["camera", "microphone"].contains(device) else {
      throw PolkaCoreError.invalid("Неизвестное устройство")
    }
    var next = preferences
    next[device + "Enabled"] = enabled
    try settings.set(key: "mediaIndicatorTracking", value: next)
    preferences = next
    publish()
    restart()
  }
  private func publish() {
    model.settings.cameraEnabled = preferences["cameraEnabled"] == true
    model.settings.microphoneEnabled = preferences["microphoneEnabled"] == true
  }
  private func restart() {
    epoch += 1
    timer?.invalidate()
    timer = nil
    lastState = nil
    for overlay in overlays.values { overlay.orderOut(nil) }
    guard !fixture, suspended.isEmpty, preferences.values.contains(true) else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    poll()
  }
  private func poll() {
    guard !polling else { return }
    polling = true
    let generation = epoch
    let args =
      (model.settings.cameraEnabled ? ["--camera"] : [])
      + (model.settings.microphoneEnabled ? ["--microphone"] : [])
    Task {
      defer { polling = false }
      let data = try? await NativeCommand.run(NativeProfile.helper("media-probe"), arguments: args)
      guard generation == epoch else { return }
      let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      let camera = NativeMediaPresentation.state(
        (object?["camera"] as? [String: Any])?["state"], enabled: model.settings.cameraEnabled)
      let microphone = NativeMediaPresentation.state(
        (object?["microphone"] as? [String: Any])?["state"],
        enabled: model.settings.microphoneEnabled)
      let state = NativeMediaPresentation(camera: camera, microphone: microphone)
      if model.settings.mediaActivity != state.label { model.settings.mediaActivity = state.label }
      render(state)

    }
  }
  private func render(_ state: NativeMediaPresentation) {
    lastState = state
    for screen in NSScreen.screens {
      let id = String(
        describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          ?? screen.frame)
      let panel: NSPanel
      if let existing = overlays[id] {
        panel = existing
      } else {
        panel = NativeMediaIndicatorPanel()
        overlays[id] = panel
      }
      if !state.visible {
        panel.orderOut(nil)
        continue
      }
      let geometry = NativeMediaIndicatorGeometry(screen: screen)
      panel.setFrame(geometry.panelFrame, display: true)
      let view = NativeMediaIndicatorView(state: state, geometry: geometry)
      if let host = panel.contentView as? NSHostingView<NativeMediaIndicatorView> {
        host.rootView = view
      } else {
        panel.contentView = NSHostingView(rootView: view)
      }
      panel.orderFrontRegardless()

    }
    let ids = Set(
      NSScreen.screens.map {
        String(
          describing: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? $0.frame)
      })
    for (id, panel) in overlays where !ids.contains(id) {
      panel.close()
      overlays.removeValue(forKey: id)
    }
  }
  func refreshGeometry() {
    guard suspended.isEmpty, let lastState else { return }
    render(lastState)
  }
  /// The shared desktop harness injects activity; it never starts device probes.
  func showFixture(_ state: NativeMediaPresentation) -> [NSPanel] {
    guard fixture, NativeProfile.isolatedFixture, suspended.isEmpty else { return [] }
    render(state)
    return Array(overlays.values)
  }
  func suspend(_ reason: String) {
    suspended.insert(reason)
    restart()
  }
  func resume(_ reason: String) {
    suspended.remove(reason)
    restart()
  }
  func stop() {
    epoch += 1
    timer?.invalidate()
    timer = nil
    lastState = nil
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    screenObserver = nil
    for overlay in overlays.values { overlay.close() }
    overlays.removeAll()
  }
}

struct NativeMediaPresentation {
  var camera: String
  var microphone: String
  static func state(_ value: Any?, enabled: Bool) -> String {
    guard enabled else { return "disabled" }
    let state = value as? String ?? "unknown"
    return ["active", "inactive", "disabled"].contains(state) ? state : "unknown"
  }
  var visible: Bool { [camera, microphone].contains { ["active", "unknown"].contains($0) } }
  var label: String {
    func label(_ name: String, _ state: String) -> String {
      let labels = [
        "active": "используется", "inactive": "не используется",
        "disabled": "отслеживание выключено", "unknown": "статус недоступен",
      ]
      return "\(name): \(labels[state] ?? labels["unknown"]!)."
    }
    return label("Камера", camera) + " " + label("Микрофон", microphone)
  }
}
struct NativeMediaIndicatorView: View {
  var state: NativeMediaPresentation
  var geometry: NativeMediaIndicatorGeometry
  private let cameraColor = Color(red: 1, green: 81 / 255, blue: 78 / 255)
  private let micColor = Color(red: 242 / 255, green: 163 / 255, blue: 69 / 255)
  private let badgeWidth: CGFloat = 110
  private let badgeHeight: CGFloat = 38
  var body: some View {
    GeometryReader { container in
      let notched = geometry.hasNotch
      let center = notched ? geometry.notch.midX : container.size.width / 2
      ZStack(alignment: .top) {
        if notched {
          geometry.contour.stroke(
            rimStyle,
            style: StrokeStyle(lineWidth: geometry.strokeWidth, lineCap: .butt, lineJoin: .round))
        } else {
          // A filled badge keeps the icons legible when there is no housing.
          UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(rimStyle)
            .frame(width: badgeWidth, height: badgeHeight)
        }
        if ["active", "unknown"].contains(state.camera) {
          device("video", value: state.camera, color: cameraColor, notched: notched)
            .position(
              x: center
                - (notched
                  ? geometry.notch.width / 2 + 38
                  : state.microphone == "inactive" || state.microphone == "disabled"
                    ? 0 : badgeWidth / 4),
              y: notched ? 23 : badgeHeight / 2)
        }
        if ["active", "unknown"].contains(state.microphone) {
          device("mic", value: state.microphone, color: micColor, notched: notched)
            .position(
              x: center
                + (notched
                  ? geometry.notch.width / 2 + 38
                  : state.camera == "inactive" || state.camera == "disabled" ? 0 : badgeWidth / 4),
              y: notched ? 23 : badgeHeight / 2)
        }
      }.frame(width: container.size.width, height: container.size.height, alignment: .top)
    }.accessibilityElement(children: .ignore).accessibilityLabel(state.label).allowsHitTesting(
      false)
  }
  private var rimStyle: AnyShapeStyle {
    if state.camera == "active", state.microphone == "active" {
      let split = geometry.hasNotch ? geometry.notch.midX / geometry.panelFrame.width : 0.5
      return AnyShapeStyle(
        LinearGradient(
          stops: [
            .init(color: cameraColor, location: 0), .init(color: cameraColor, location: split),
            .init(color: micColor, location: split), .init(color: micColor, location: 1),
          ], startPoint: .leading, endPoint: .trailing))
    }
    return AnyShapeStyle(
      state.camera == "active"
        ? cameraColor
        : state.microphone == "active"
          ? micColor
          : Color(red: 169 / 255, green: 175 / 255, blue: 166 / 255))
  }
  private func device(_ symbol: String, value: String, color: Color, notched: Bool) -> some View {
    // SF Symbols have different artwork heights at the same font size.
    // Fit their aspect ratios to a shared height before centering the cells.
    Image(systemName: symbol).resizable().scaledToFit()
      .font(.system(size: 25, weight: notched ? .semibold : .medium))
      .foregroundStyle(
        notched
          ? (value == "unknown" ? .gray : color)
          : Color(red: 33 / 255, green: 27 / 255, blue: 22 / 255)
      )
      .frame(height: notched ? 24 : 20)
      .frame(width: 40, height: notched ? 40 : 36)
      .background(
        notched ? Color(red: 23 / 255, green: 19 / 255, blue: 19 / 255) : .clear,
        in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay(alignment: .bottomTrailing) {
        if value == "unknown" {
          Image(systemName: "questionmark.circle.fill").font(.system(size: 13)).foregroundStyle(
            .gray)
        }
      }
  }
}
