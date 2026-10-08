import AppKit
import PolkaCore
import SwiftUI

@MainActor final class NativeMediaMonitor {
  private var timer: Timer?
  private var polling = false
  private var epoch = 0
  private var overlays: [String: NSPanel] = [:]
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
    for screen in NSScreen.screens {
      let id = String(
        describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          ?? screen.frame)
      let panel: NSPanel
      if let existing = overlays[id] {
        panel = existing
      } else {
        panel = NSPanel(
          contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
          defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        overlays[id] = panel
      }
      if !state.visible {
        panel.orderOut(nil)
        continue
      }
      let notchWidth =
        screen.auxiliaryTopLeftArea.flatMap { left in
          screen.auxiliaryTopRightArea.map { max(0, $0.minX - left.maxX) }
        } ?? 0
      let notchHeight = notchWidth > 0 ? screen.safeAreaInsets.top : 0
      let center =
        screen.auxiliaryTopLeftArea.flatMap { left in
          screen.auxiliaryTopRightArea.map { (left.maxX + $0.minX) / 2 }
        } ?? screen.frame.midX
      let width = min(screen.frame.width, notchWidth > 0 ? notchWidth + 124 : 116)
      let height = min(screen.frame.height, max(46, notchHeight + 14))
      panel.setFrame(
        NSRect(
          x: max(screen.frame.minX, min(screen.frame.maxX - width, center - width / 2)),
          y: screen.frame.maxY - height, width: width, height: height), display: true)
      panel.contentView = NSHostingView(
        rootView: NativeMediaIndicatorView(
          state: state, notchWidth: notchWidth, notchHeight: notchHeight))
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
  var notchWidth: CGFloat
  var notchHeight: CGFloat
  private let cameraColor = Color(red: 1, green: 81 / 255, blue: 78 / 255)
  private let micColor = Color(red: 242 / 255, green: 163 / 255, blue: 69 / 255)
  var body: some View {
    GeometryReader { geometry in
      let notched = notchWidth > 0
      let rimWidth = notched ? notchWidth + 20 : 110
      let rimHeight = notched ? notchHeight + 12 : 44
      ZStack(alignment: .top) {
        // Extending the rounded rectangle upward gives square top corners.
        ZStack {
          if state.camera == "active", state.microphone == "active" {
            HStack(spacing: 0) {
              cameraColor
              micColor
            }
          } else {
            (state.camera == "active"
              ? cameraColor
              : state.microphone == "active"
                ? micColor : Color(red: 169 / 255, green: 175 / 255, blue: 166 / 255))
          }
        }.frame(width: rimWidth, height: rimHeight + 20)
          .clipShape(RoundedRectangle(cornerRadius: notched ? 20 : 18))
          .offset(y: -20)
        if ["active", "unknown"].contains(state.camera) {
          device("video", value: state.camera, color: cameraColor, notched: notched)
            .position(
              x: geometry.size.width / 2
                - (notched
                  ? notchWidth / 2 + 38
                  : state.microphone == "inactive" || state.microphone == "disabled" ? 0 : 23),
              y: notched ? 23 : 21)
        }
        if ["active", "unknown"].contains(state.microphone) {
          device("mic", value: state.microphone, color: micColor, notched: notched)
            .position(
              x: geometry.size.width / 2
                + (notched
                  ? notchWidth / 2 + 38
                  : state.camera == "inactive" || state.camera == "disabled" ? 0 : 23),
              y: notched ? 23 : 21)
        }
      }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
    }.accessibilityElement(children: .ignore).accessibilityLabel(state.label).allowsHitTesting(
      false)
  }
  private func device(_ symbol: String, value: String, color: Color, notched: Bool) -> some View {
    Image(systemName: symbol).font(.system(size: 25, weight: .semibold))
      .foregroundStyle(
        notched
          ? (value == "unknown" ? .gray : color)
          : Color(red: 33 / 255, green: 27 / 255, blue: 22 / 255)
      )
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
