import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Bounded, explicit research utility. No background hooks or persistent changes.
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "permissions":
    print("accessibility=\(AXIsProcessTrusted()) postEvents=\(CGPreflightPostEventAccess()) screenCapture=\(CGPreflightScreenCaptureAccess())")
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
    fputs("desktop_probe permissions | windows [owner] | click x y | click-app pid x y holdMS | key pid keycode | chord keycode holdMS\n", stderr)
    exit(2)
}
