import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Bounded, explicit research utility. No background hooks or persistent changes.
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "permissions":
    print("accessibility=\(AXIsProcessTrusted()) postEvents=\(CGPreflightPostEventAccess()) screenCapture=\(CGPreflightScreenCaptureAccess())")
case "activate":
    guard args.count == 2, let pid = Int32(args[1]), AXIsProcessTrusted() else { exit(2) }
    let app = AXUIElementCreateApplication(pid)
    guard AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success else { exit(3) }
    let deadline = Date(timeIntervalSinceNow: 2)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { exit(4) }
    print("active=\(pid)")
case "watch-chords", "watch-mouse":
    let mouse = args.first == "watch-mouse"
    let mask = mouse ? ((1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue))
        : ((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue))
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .leftMouseDown || type == .leftMouseUp {
            print("type=\(type.rawValue) pid=\(event.getIntegerValueField(.eventSourceUnixProcessID)) time=\(event.timestamp) x=\(event.location.x) y=\(event.location.y)")
            fflush(stdout)
        } else if [126, 125, 58, 59].contains(key) {
            print("type=\(type.rawValue) key=\(key) flags=\(String(event.flags.rawValue, radix: 16))")
            fflush(stdout)
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil) else { exit(3) }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 8))
    CFMachPortInvalidate(tap)
case "windows":
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let filter = args.count > 1 ? args[1].lowercased() : "zwift"
    for w in windows where (w[kCGWindowOwnerName as String] as? String ?? "").lowercased().contains(filter) {
        let data = try JSONSerialization.data(withJSONObject: w, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
case "element", "press-element":
    guard args.count == 3, let pid = Int32(args[1]) else { exit(2) }
    guard AXIsProcessTrusted() else { fputs("Accessibility access is required for element lookup\n", stderr); exit(3) }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &result) == .success else { return nil }
        return result
    }
    var pending: [(AXUIElement, Int)] = [(app, 0)]
    var cursor = 0
    while cursor < pending.count && cursor < 1500 {
        let (element, depth) = pending[cursor]
        cursor += 1
        let identifier = attribute(element, kAXIdentifierAttribute as CFString) as? String
        let label = attribute(element, kAXDescriptionAttribute as CFString) as? String
        let title = attribute(element, kAXTitleAttribute as CFString) as? String
        let labelQuery = args[2].hasPrefix("label:") ? String(args[2].dropFirst(6)) : nil
        if identifier == args[2] || (labelQuery != nil && (label == labelQuery || title == labelQuery)) {
            if args.first == "press-element" {
                guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { exit(5) }
                print("pressed")
                exit(0)
            }
            guard let position = attribute(element, kAXPositionAttribute as CFString),
                  let size = attribute(element, kAXSizeAttribute as CFString),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { exit(5) }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { exit(5) }
            let result: [String: Any] = ["identifier": args[2], "x": point.x, "y": point.y,
                                         "width": dimensions.width, "height": dimensions.height,
                                         "enabled": attribute(element, kAXEnabledAttribute as CFString) as? Bool ?? false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
            exit(0)
        }
        if depth < 20, let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            pending += children.map { ($0, depth + 1) }
        }
    }
    fputs("Accessibility element not found: \(args[2])\n", stderr)
    exit(4)
case "click", "click-app", "direct-click":
    let direct = args.first == "direct-click"
    let specific = args.first != "click"
    let start = specific ? 2 : 1
    guard args.count == (specific ? 5 : 3), let x = Double(args[start]), let y = Double(args[start + 1]) else { exit(2) }
    let holdMS = specific ? Int(args[4]) ?? 250 : 250
    guard (20...5000).contains(holdMS) else { exit(2) }
    guard CGPreflightPostEventAccess() else { fputs("Post-event access denied\n", stderr); exit(3) }
    let target = specific ? Int32(args[1]).flatMap { NSRunningApplication(processIdentifier: $0) }
        : NSWorkspace.shared.runningApplications.first(where: { $0.executableURL?.lastPathComponent == "ZwiftAppSilicon" })
    if !direct, let game = target {
        print("activate=\(game.activate(options: [.activateAllWindows]))")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
    }
    let p = CGPoint(x: x, y: y)
    if !direct {
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    usleep(150_000)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
    down?.setIntegerValueField(.mouseEventClickState, value: 1)
    up?.setIntegerValueField(.mouseEventClickState, value: 1)
    if direct, let target {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        guard let window = windows.first(where: { $0[kCGWindowOwnerPID as String] as? Int32 == target.processIdentifier }),
              let id = window[kCGWindowNumber as String] as? Int64 else { exit(4) }
        for event in [down, up] {
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: id)
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: id)
        }
        down?.postToPid(target.processIdentifier)
    } else { down?.post(tap: .cghidEventTap) }
    usleep(useconds_t(holdMS * 1000))
    if direct, let target { up?.postToPid(target.processIdentifier) }
    else { up?.post(tap: .cghidEventTap) }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
case "key":
    guard args.count == 3, let pid = Int32(args[1]), let code = UInt16(args[2]) else { exit(2) }
    guard CGPreflightPostEventAccess() else { exit(3) }
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.postToPid(pid)
    usleep(60_000)
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.postToPid(pid)
case "chord":
    guard args.count == 3, let code = UInt16(args[1]), let ms = UInt32(args[2]), ms <= 5000 else { exit(2) }
    guard CGPreflightPostEventAccess() else { exit(3) }
    func modifier(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags; event?.post(tap: .cghidEventTap); usleep(50_000)
    }
    modifier(59, true, [.maskControl])
    modifier(58, true, [.maskControl, .maskAlternate])
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    // Arrow keys carry the keypad/function flags as well as their modifiers.
    // Without these, the WindowServer does not match the registered hotkey.
    down?.flags = [.maskControl, .maskAlternate, .maskSecondaryFn, .maskNumericPad]
    up?.flags = [.maskControl, .maskAlternate, .maskSecondaryFn, .maskNumericPad]
    down?.post(tap: .cghidEventTap)
    usleep(ms * 1000)
    up?.post(tap: .cghidEventTap)
    modifier(58, false, [.maskControl])
    modifier(59, false, [])
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
default:
    fputs("desktop_probe permissions | activate pid | windows [owner] | element pid identifier | press-element pid identifier | click x y | click-app pid x y holdMS | key pid keycode | chord keycode holdMS\n", stderr)
    exit(2)
}
