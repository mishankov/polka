import AppKit
import Carbon

@MainActor final class GlobalShortcuts {
  private var bindings: [String: (EventHotKeyRef, () -> Void, UInt32, UInt32)] = [:]
  private var identifiers: [UInt32: String] = [:]
  private var nextID: UInt32 = 1
  private var handler: EventHandlerRef?
  private var pressed = Set<UInt32>()
  init() {
    var specs = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context -> OSStatus in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var hotKey = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
        guard status == noErr else { return status }
        let instance = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
          if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            instance.pressed.remove(hotKey.id)
            return
          }
          guard instance.pressed.insert(hotKey.id).inserted,
            let name = instance.identifiers[hotKey.id]
          else { return }
          instance.bindings[name]?.1()
        }
        return noErr
      }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }
  static func parse(_ value: String) throws -> (UInt32, UInt32) {
    let parts = value.split(separator: "+").map(String.init)
    guard let key = parts.last, parts.count >= 2 else { throw unavailable() }
    var modifiers: UInt32 = 0
    for modifier in parts.dropLast() {
      switch modifier {
      case "Command", "CommandOrControl": modifiers |= UInt32(cmdKey)
      case "Control": modifiers |= UInt32(controlKey)
      case "Alt", "Option": modifiers |= UInt32(optionKey)
      case "Shift": modifiers |= UInt32(shiftKey)
      default: throw unavailable()
      }
    }
    guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else { throw unavailable() }
    let keys: [String: UInt32] = [
      "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11,
      "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21,
      "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "O": 31, "U": 32, "I": 34, "P": 35,
      "L": 37, "J": 38, "K": 40, "N": 45, "M": 46, "Space": 49, "F1": 122, "F2": 120, "F3": 99,
      "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103,
      "F12": 111,
    ]
    guard let code = keys[key] else { throw unavailable() }
    return (code, modifiers)
  }
  private static func unavailable() -> NSError {
    NSError(
      domain: "Polka.Shortcut", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Выберите сочетание с Command, Control или Option"])
  }
  /// Reserve the replacement first. Persist failure leaves the prior binding intact.
  func set(
    _ name: String, accelerator: String, persist: () throws -> Void, action: @escaping () -> Void
  ) throws {
    if accelerator.isEmpty {
      try persist()
      remove(name)
      return
    }
    let (code, modifiers) = try Self.parse(accelerator)
    if let old = bindings[name], old.2 == code, old.3 == modifiers {
      try persist()
      bindings[name] = (old.0, action, code, modifiers)
      return
    }
    let id = nextID
    nextID += 1
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      code, modifiers, EventHotKeyID(signature: 0x504f_4c4b, id: id), GetApplicationEventTarget(),
      0, &reference)
    guard status == noErr, let reference else {
      throw NSError(
        domain: "Polka.Shortcut", code: Int(status),
        userInfo: [
          NSLocalizedDescriptionKey:
            "Сочетание недоступно или занято другой программой. Выберите другое."
        ])
    }
    do { try persist() } catch {
      UnregisterEventHotKey(reference)
      throw error
    }
    remove(name)
    identifiers[id] = name
    bindings[name] = (reference, action, code, modifiers)
  }
  func remove(_ name: String) {
    if let old = bindings.removeValue(forKey: name) { UnregisterEventHotKey(old.0) }
    for id in identifiers.filter({ $0.value == name }).keys {
      pressed.remove(id)
      identifiers.removeValue(forKey: id)
    }
  }
  func stop() {
    for binding in bindings.values { UnregisterEventHotKey(binding.0) }
    bindings.removeAll()
    identifiers.removeAll()
    pressed.removeAll()
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
}
