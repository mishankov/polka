import AppKit
import Foundation

func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}
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
    emit(["type": "screens", "displays": displays])
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
screens()
if CommandLine.arguments.contains("--screens") { exit(0) }
let observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in screens() }
let pasteboard = NSPasteboard.general
var previous = pasteboard.changeCount
emit(["type": "ready"])
let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
    let count = pasteboard.changeCount
    guard count != previous else { return }
    previous = count
    // Emit only a change signal; Electron reads a consistent clipboard snapshot on demand.
    emit(["type": "clipboard"])
}
application.run()
