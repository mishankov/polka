import AppKit
import ApplicationServices
import Foundation

func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}
var previousScreens: Data?
func screens() {
    let displays: [[String: Any]] = NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        var result: [String: Any] = ["id": number.intValue, "height": 0, "x": 0, "width": 0]
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            result["height"] = screen.safeAreaInsets.top
            result["x"] = left.maxX - screen.frame.minX
            result["width"] = right.minX - left.maxX
        }
        return result
    }
    // Activation can emit screen-change notifications without changing geometry.
    // Do not dismiss an open shelf for an identical screen snapshot.
    guard let snapshot = try? JSONSerialization.data(withJSONObject: displays, options: .sortedKeys),
          snapshot != previousScreens else { return }
    previousScreens = snapshot
    emit(["type": "screens", "displays": displays])
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
screens()
if CommandLine.arguments.contains("--screens") { exit(0) }
// Keep AX references in this trusted native process; field contents never cross IPC.
struct PasteTarget {
    let token: String
    let app: NSRunningApplication
    let field: AXUIElement?
    let identity: FocusIdentity?
    let selection: CFTypeRef?
    let window: AXUIElement?
}
var pasteTarget: PasteTarget?
var pasteGeneration = 0
let ownerPID = CommandLine.arguments.dropFirst().first.flatMap(Int32.init)
func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
// Rich editors may recreate their AX object when the app is reactivated.
// Match only non-content metadata, and only inside the original window.
struct FocusIdentity {
    let role: String?
    let identifier: String?
    let frame: CGRect?
}
func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}
func focusIdentity(_ element: AXUIElement) -> FocusIdentity {
    AXUIElementSetMessagingTimeout(element, 0.08)
    let role = axValue(element, kAXRoleAttribute) as? String
    let identifier = axValue(element, kAXIdentifierAttribute) as? String
    var frame: CGRect?
    if let position = axValue(element, kAXPositionAttribute), let size = axValue(element, kAXSizeAttribute),
       CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
        var point = CGPoint.zero, dimensions = CGSize.zero
        if AXValueGetValue(position as! AXValue, .cgPoint, &point),
           AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 {
            frame = CGRect(origin: point, size: dimensions)
        }
    }
    return FocusIdentity(role: role, identifier: identifier, frame: frame)
}
func focusedField(_ appElement: AXUIElement, pid: pid_t) -> AXUIElement? {
    var field = axElement(appElement, kAXFocusedUIElementAttribute)
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.08)
    if let global = axElement(system, kAXFocusedUIElementAttribute) {
        var focusedPID: pid_t = 0
        if AXUIElementGetPid(global, &focusedPID) == .success && focusedPID == pid { field = global }
    }
    // Some AppKit/WebKit containers forward focus to a child rather than reporting
    // the editor as the application's immediate focused element.
    for _ in 0..<4 {
        guard let current = field else { break }
        AXUIElementSetMessagingTimeout(current, 0.08)
        guard let child = axElement(current, kAXFocusedUIElementAttribute), !CFEqual(child, current) else { break }
        field = child
    }
    if let root = field, let role = axValue(root, kAXRoleAttribute) as? String,
       ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
        var queue = [root]
        var examined = 0
        let deadline = Date().addingTimeInterval(0.12)
        while !queue.isEmpty && examined < 120 && Date() < deadline {
            let child = queue.removeFirst()
            examined += 1
            AXUIElementSetMessagingTimeout(child, 0.025)
            if axValue(child, kAXFocusedAttribute) as? Bool == true,
               let childRole = axValue(child, kAXRoleAttribute) as? String,
               [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(childRole) { return child }
            if let children = axValue(child, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(120 - examined))
            }
        }
    }
    return field
}
func sameField(_ field: AXUIElement, target: PasteTarget) -> Bool {
    if let original = target.field, CFEqual(field, original) { return true }
    guard target.window != nil, let saved = target.identity, let role = saved.role,
          [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
          axValue(field, kAXRoleAttribute) as? String == role else { return false }
    let current = focusIdentity(field)
    if let identifier = saved.identifier, !identifier.isEmpty, identifier == current.identifier { return true }
    guard let before = saved.frame, let after = current.frame else { return false }
    return abs(before.minX - after.minX) < 1 && abs(before.minY - after.minY) < 1 &&
           abs(before.width - after.width) < 1 && abs(before.height - after.height) < 1
}
func matchingField(in window: AXUIElement, target: PasteTarget, until deadline: Date) -> AXUIElement? {
    var queue = [window]
    var examined = 0
    // Reacquire a recreated editor by identity in the saved window, never by title
    // or by taking the first text field in the app.
    while !queue.isEmpty && examined < 120 && Date() < deadline {
        let element = queue.removeFirst()
        examined += 1
        AXUIElementSetMessagingTimeout(element, 0.025)
        if sameField(element, target: target) { return element }
        if let children = axValue(element, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children.prefix(120 - examined))
        }
    }
    return nil
}
func focusField(_ field: AXUIElement) {
    let result = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    if result != .success {
        var actions: CFArray?
        if AXUIElementCopyActionNames(field, &actions) == .success,
           let names = actions as? [String], names.contains(kAXPressAction) {
            AXUIElementPerformAction(field, kAXPressAction as CFString)
        }
    }
}
func reply(_ id: String, _ result: [String: Any]) {
    emit(["type": "paste.reply", "id": id, "result": result])
}
func handlePasteCommand(_ command: [String: Any]) {
    guard let id = command["id"] as? String, let method = command["method"] as? String else { return }
    if method == "clipboardUnchanged" {
        reply(id, ["unchanged": String(NSPasteboard.general.changeCount) == command["count"] as? String]); return
    }
    if method == "status" || method == "requestAccess" {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: method == "requestAccess"] as CFDictionary
        reply(id, ["trusted": AXIsProcessTrustedWithOptions(options)])
        return
    }
    if method == "cancel" {
        pasteGeneration += 1
        pasteTarget = nil
        reply(id, [:])
        return
    }
    if method == "capture" {
        pasteGeneration += 1
        pasteTarget = nil
        let trusted = AXIsProcessTrusted()
        guard trusted, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            reply(id, ["trusted": trusted]); return
        }
        let appElement = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let field = focusedField(appElement, pid: front.processIdentifier)
        let window = axElement(appElement, kAXFocusedWindowAttribute)
        guard field != nil || window != nil else {
            reply(id, ["trusted": trusted, "reason": "no-target"]); return
        }
        let target = PasteTarget(token: UUID().uuidString, app: front, field: field,
                                 identity: field.map(focusIdentity),
                                 selection: field.flatMap { axValue($0, kAXSelectedTextRangeAttribute) }, window: window)
        if let window = target.window { AXUIElementSetMessagingTimeout(window, 0.15) }
        pasteTarget = target
        reply(id, ["trusted": true, "token": target.token])
        return
    }
    guard method == "paste", let token = command["token"] as? String,
          let target = pasteTarget, target.token == token else {
        reply(id, ["sent": false, "reason": "target-unavailable"]); return
    }
    pasteTarget = nil // A selection can issue at most one paste.
    pasteGeneration += 1
    let generation = pasteGeneration
    guard AXIsProcessTrusted(), !target.app.isTerminated,
          let expiresAt = command["expiresAt"] as? Double,
          Date().timeIntervalSince1970 * 1000 < expiresAt else {
        reply(id, ["sent": false, "reason": "target-unavailable"]); return
    }
    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard frontPID == ownerPID || frontPID == target.app.processIdentifier else {
        reply(id, ["sent": false, "reason": "app-changed"]); return
    }
    let changeCount = NSPasteboard.general.changeCount
    let targetElement = AXUIElementCreateApplication(target.app.processIdentifier)
    AXUIElementSetMessagingTimeout(targetElement, 0.15)
    _ = AXUIElementSetAttributeValue(targetElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let window = target.window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
    _ = target.app.activate(options: [])
    let deadline = min(Date().addingTimeInterval(1.0), Date(timeIntervalSince1970: expiresAt / 1000))
    var focusAttempts = 0
    var lastFocusAttempt = Date.distantPast
    var resolvedField = target.field
    var restoredSelection = false
    var focusStableSince: Date?
    var lastReason = "focus-not-restored"
    func finishWhenFocused() {
        guard generation == pasteGeneration, !target.app.isTerminated, Date() < deadline,
              NSPasteboard.general.changeCount == changeCount, AXIsProcessTrusted() else {
            reply(id, ["sent": false, "reason": lastReason]); return
        }
        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // If the user switches elsewhere, never send a keystroke into that app.
        guard activePID == ownerPID || activePID == target.app.processIdentifier else {
            reply(id, ["sent": false, "reason": "app-changed"]); return
        }
        let appElement = AXUIElementCreateApplication(target.app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        var focused = focusedField(appElement, pid: target.app.processIdentifier)
        let currentWindow = axElement(appElement, kAXFocusedWindowAttribute)
        let windowMatches = target.window.map { original in currentWindow.map { CFEqual(original, $0) } ?? false } ?? true
        if activePID == target.app.processIdentifier && windowMatches && target.field != nil &&
           (focusAttempts == 0 || !(focused.map { sameField($0, target: target) } ?? false)) && focusAttempts < 3 &&
           Date().timeIntervalSince(lastFocusAttempt) >= 0.12 {
            // An inactive app can accept activation while rejecting field focus.
            // Restore the responder only after the app and its window are active.
            focusAttempts += 1
            lastFocusAttempt = Date()
            if let original = resolvedField { focusField(original) }
            focused = focusedField(appElement, pid: target.app.processIdentifier)
            if !(focused.map { sameField($0, target: target) } ?? false), let window = target.window,
               let replacement = matchingField(in: window, target: target, until: min(deadline, Date().addingTimeInterval(0.15))) {
                resolvedField = replacement
                focusField(replacement)
                focused = focusedField(appElement, pid: target.app.processIdentifier)
            }
        }
        // When the app exposes no field, restoring its exact window preserves its
        // own first responder; do not require an AX text editor that it doesn't publish.
        let fieldMatches = target.field == nil ? windowMatches : focused.map { sameField($0, target: target) } ?? false
        let modifiers = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        let ready = activePID == target.app.processIdentifier && windowMatches && fieldMatches && modifiers.isEmpty
        if !ready { focusStableSince = nil }
        else if focusStableSince == nil { focusStableSince = Date() }
        lastReason = !windowMatches ? "window-changed" : !fieldMatches ? "field-changed" : !modifiers.isEmpty ? "modifiers-held" : "focus-not-restored"
        if ready, let stable = focusStableSince, Date().timeIntervalSince(stable) >= 0.08 {
            if !restoredSelection, let field = focused, let selection = target.selection {
                _ = AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, selection)
                restoredSelection = true
            }
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
                  let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false),
                  Date() < deadline, generation == pasteGeneration,
                  NSPasteboard.general.changeCount == changeCount,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier else {
                reply(id, ["sent": false, "reason": "focus-not-restored"]); return
            }
            commandDown.flags = .maskCommand
            down.flags = .maskCommand
            up.flags = .maskCommand
            commandUp.flags = []
            // Use the normal keyboard event stream so AppKit/SwiftUI and web
            // editors receive the same complete shortcut as a physical Command-V.
            // Never retry through another transport: a handled paste may have no AX feedback.
            for event in [commandDown, down, up, commandUp] { event.post(tap: .cghidEventTap) }
            reply(id, ["sent": true])
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: finishWhenFocused)
        } else { reply(id, ["sent": false, "reason": lastReason]) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: finishWhenFocused)
}
// The parent owns stdin. EOF terminates the helper, including any pending paste.
DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() {
        guard line.utf8.count < 4096, let data = line.data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        DispatchQueue.main.async { handlePasteCommand(command) }
    }
    DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
}

let observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in screens() }
let pasteboard = NSPasteboard.general
var previous = pasteboard.changeCount
var previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
emit(["type": "ready"])
let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
    let count = pasteboard.changeCount
    let front = NSWorkspace.shared.frontmostApplication
    let stable = front?.processIdentifier == previousApp
    previousApp = front?.processIdentifier
    guard count != previous else { return }
    previous = count
    // Emit only a change signal; Electron reads a consistent clipboard snapshot on demand.
    var message: [String: Any] = ["type": "clipboard", "count": count]
    // Foreground attribution is a heuristic, never a claim about pasteboard ownership.
    if stable, let bundleId = front?.bundleIdentifier { message["sourceBundleId"] = bundleId }
    emit(message)
}
application.run()
