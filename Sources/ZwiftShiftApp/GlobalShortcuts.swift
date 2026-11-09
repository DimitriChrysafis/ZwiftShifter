import AppKit
import Carbon
import ZwiftShiftCore

@MainActor final class GlobalShortcuts {
  private var handler: EventHandlerRef?
  private var registrations: [EventHotKeyRef] = []
  private var previous: Settings?
  private var enabled = false
  private var attemptedEnabled: Bool?
  private(set) var failure: String?
  var onPress: ((ShiftDirection, Bool) -> Void)?

  func update(settings: Settings, enabled: Bool) throws {
    let shouldEnable = enabled && settings.shortcutsEnabled
    guard attemptedEnabled != shouldEnable || previous != settings else { return }
    unregister()
    previous = settings
    attemptedEnabled = shouldEnable
    failure = nil
    guard shouldEnable else { return }
    if handler == nil {
      var events = [
        EventTypeSpec(
          eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(
          eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
      ]
      let result = InstallEventHandler(
        GetApplicationEventTarget(),
        { _, event, context in
          guard let event, let context else { return OSStatus(eventNotHandledErr) }
          var id = EventHotKeyID()
          guard
            GetEventParameter(
              event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
              nil,
              MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
            id.signature == 0x5a53_4846, [1, 2].contains(id.id)
          else { return OSStatus(eventNotHandledErr) }
          let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
          MainActor.assumeIsolated {
            owner.onPress?(
              id.id == 1 ? .up : .down, GetEventKind(event) == UInt32(kEventHotKeyPressed))
          }
          return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
      guard result == noErr else {
        failure = "Cannot register shortcut handler (\(result))."
        throw ShiftError.message(failure!)
      }
    }
    do {
      for (index, shortcut) in [settings.upShortcut, settings.downShortcut].enumerated() {
        let modifiers =
          (shortcut.control ? UInt32(controlKey) : 0) | (shortcut.option ? UInt32(optionKey) : 0)
          | (shortcut.command ? UInt32(cmdKey) : 0) | (shortcut.shift ? UInt32(shiftKey) : 0)
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(
          shortcut.keyCode, modifiers,
          EventHotKeyID(signature: 0x5a53_4846, id: UInt32(index + 1)),
          GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else {
          throw ShiftError.message(
            "Shortcut \(shortcut.label) is unavailable (\(result)). Choose another combination.")
        }
        registrations.append(reference)
      }
      self.enabled = true
    } catch {
      unregister()
      failure = error.localizedDescription
      throw error
    }
  }
  func unregister() {
    for reference in registrations { UnregisterEventHotKey(reference) }
    registrations.removeAll()
    enabled = false
  }
  func stop() {
    unregister()
    if let handler {
      RemoveEventHandler(handler)
      self.handler = nil
    }
  }
}
