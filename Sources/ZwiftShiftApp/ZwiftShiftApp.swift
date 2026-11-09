import AppKit
import SwiftUI
import ZwiftShiftCore

enum AppPanel: String, Identifiable {
  case settings, connection, activity, phone
  var id: String { rawValue }
}

@MainActor final class AppModel: ObservableObject {
  @Published var panel: AppPanel?
  @Published var status = ServiceStatus(settings: ZwiftShiftCore.Settings())
  @Published var fatalError: String?
  @Published var shortcutError: String?
  private let shortcuts = GlobalShortcuts()
  private(set) var service: ShiftService?
  private var sleepObserver: NSObjectProtocol?
  init() {
    shortcuts.onPress = { [weak self] direction, pressed in
      let source = "keyboard-\(direction.rawValue)"
      if pressed {
        self?.service?.beginHold(direction, source: source)
      } else {
        self?.service?.endHold(source: source)
      }
    }
    start()
    sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.service?.cancelShifting() }
    }
  }
  func start() {
    service?.stop()
    fatalError = nil
    do {
      let service = try ShiftService()
      self.service = service
      service.onUpdate = { [weak self] status in
        guard let self else { return }
        self.status = status
        do { try self.shortcuts.update(settings: status.settings, enabled: status.canShift) } catch
        { self.shortcutError = error.localizedDescription }
        self.shortcutError = self.shortcuts.failure
      }
      try service.start()
    } catch { fatalError = error.localizedDescription }
  }
  func press(_ direction: ShiftDirection, down: Bool) {
    if down {
      service?.beginHold(direction, source: "mouse-\(direction.rawValue)")
    } else {
      service?.endHold(source: "mouse-\(direction.rawValue)")
    }
  }
  func single(_ direction: ShiftDirection) { service?.shift(direction) { _ in } }
  func save(_ settings: ZwiftShiftCore.Settings) throws { try service?.updateSettings(settings) }
  func stop() {
    shortcuts.stop()
    service?.stop()
    if let sleepObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
      self.sleepObserver = nil
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    model?.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

@main struct ZwiftShiftApplication: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel()
  var body: some Scene {
    Window("ZwiftShift", id: "main") {
      Dashboard(model: model)
        .onAppear {
          delegate.model = model
          NSApp.setActivationPolicy(.regular)
        }
    }
    .defaultSize(width: 380, height: 350)
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { model.panel = .settings }
          .keyboardShortcut(",", modifiers: .command)
      }
      CommandGroup(after: .help) {
        Button("Phone controls") { model.panel = .phone }
        Button("Connection help") { model.panel = .connection }
        Button("Activity") { model.panel = .activity }
      }
    }
  }
}
