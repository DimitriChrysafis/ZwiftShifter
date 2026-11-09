import AppKit
import SwiftUI
import ZwiftShiftCore

@MainActor final class AppModel: ObservableObject {
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
    .defaultSize(width: 880, height: 710)
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .commands { CommandGroup(replacing: .newItem) {} }
  }
}

private enum Palette {
  static let background = Color(red: 0.055, green: 0.09, blue: 0.08)
  static let panel = Color(red: 0.095, green: 0.15, blue: 0.13)
  static let raised = Color(red: 0.15, green: 0.22, blue: 0.185)
  static let cream = Color(red: 0.95, green: 0.96, blue: 0.88)
  static let muted = Color(red: 0.57, green: 0.66, blue: 0.60)
  static let lime = Color(red: 0.79, green: 0.94, blue: 0.37)
  static let orange = Color(red: 1.0, green: 0.66, blue: 0.35)
}

private struct Dashboard: View {
  @ObservedObject var model: AppModel
  @State private var showingSettings = false
  @State private var showingPairing = false
  private var status: ServiceStatus { model.status }
  var body: some View {
    VStack(spacing: 22) {
      header
      if let error = model.fatalError {
        HStack {
          Image(systemName: "exclamationmark.circle")
          Text(error)
          Spacer()
          Button("Retry") { model.start() }
        }
        .font(.system(size: 13)).padding(14).background(
          Palette.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
      }
      HStack(spacing: 32) {
        gear.padding(.leading, 12)
        VStack(alignment: .leading, spacing: 14) {
          Text(status.canShift ? "CONTROLS READY" : "LET’S GET CONNECTED")
            .font(.system(size: 11, weight: .bold)).tracking(2.5).foregroundStyle(Palette.lime)
          Text(status.canShift ? "Find your\nnext gear." : "Your ride.\nYour controls.")
            .font(.system(size: 40, weight: .semibold, design: .rounded)).tracking(-1.3)
            .lineSpacing(-2)
          Text(
            status.canShift
              ? "Click, hold, or use your shortcuts."
              : "Pair ZwiftShift in Zwift to start shifting."
          )
          .font(.system(size: 14)).foregroundStyle(Palette.muted)
          if status.canShift && !status.virtualShiftingEnabled {
            Text("Connect your trainer for resistance.")
              .font(.system(size: 12)).foregroundStyle(Palette.orange)
          }
          Button {
            showingPairing = true
          } label: {
            HStack(spacing: 6) {
              Text("Connection guide")
              Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.cream)
          }.buttonStyle(.plain)
        }
        Spacer(minLength: 0)
      }
      .frame(height: 244)
      HStack(spacing: 14) {
        ShiftButton(
          direction: .down, shortcut: status.settings.downShortcut.label, enabled: status.canShift,
          action: { model.press(.down, down: $0) }, accessibleAction: { model.single(.down) })
        ShiftButton(
          direction: .up, shortcut: status.settings.upShortcut.label, enabled: status.canShift,
          action: { model.press(.up, down: $0) }, accessibleAction: { model.single(.up) })
      }
      HStack(spacing: 0) {
        statusItem(
          "ZWIFT", value: status.zwiftRunning ? "Running" : "Not running", good: status.zwiftRunning
        )
        Divider().overlay(Palette.raised).frame(height: 28)
        statusItem(
          "CONTROLLER", value: status.canShift ? "Connected" : status.state.capitalized,
          good: status.canShift)
        Divider().overlay(Palette.raised).frame(height: 28)
        statusItem("BACKEND", value: "Local network", good: status.connectedClients > 0)
      }
      activity
    }
    .padding(.horizontal, 30).padding(.top, 36).padding(.bottom, 26)
    .frame(minWidth: 820, minHeight: 670)
    .foregroundStyle(Palette.cream)
    .background(
      LinearGradient(
        colors: [Palette.panel, Palette.background, Palette.background], startPoint: .topLeading,
        endPoint: .bottomTrailing)
    )
    .preferredColorScheme(.dark)
    .sheet(isPresented: $showingSettings) { ControlsSettings(model: model, draft: status.settings) }
    .sheet(isPresented: $showingPairing) { PairingGuide(name: status.settings.deviceName) }
  }
  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "bicycle").font(.system(size: 22, weight: .bold)).foregroundStyle(
        Palette.lime)
      Text("ZWIFTSHIFT").font(.system(size: 13, weight: .heavy)).tracking(3)
      Spacer()
      HStack(spacing: 7) {
        Circle().fill(status.canShift ? Palette.lime : Palette.orange).frame(width: 6, height: 6)
        Text(status.canShift ? "CONNECTED" : "\(status.state.uppercased())")
          .font(.system(size: 10, weight: .bold)).tracking(1.3)
      }.padding(.horizontal, 12).padding(.vertical, 8).background(
        Palette.raised.opacity(0.6), in: Capsule())
      Button {
        showingSettings = true
      } label: {
        Image(systemName: "slider.horizontal.3").font(.system(size: 17)).frame(
          width: 32, height: 32)
      }
      .buttonStyle(.plain).help("Configure controls and shortcuts").accessibilityLabel(
        "Controls settings")
    }
  }
  private var gear: some View {
    let count = status.gear?.rearCount ?? 0
    let ratio = count > 0 ? min(1, max(0, Double(status.gear?.rear ?? 0) / Double(count))) : 0
    return ZStack {
      Circle().trim(from: 0.12, to: 0.88).stroke(
        Palette.raised, style: StrokeStyle(lineWidth: 5, lineCap: .round)
      ).rotationEffect(.degrees(90))
      Circle().trim(from: 0.12, to: 0.12 + 0.76 * ratio).stroke(
        Palette.lime, style: StrokeStyle(lineWidth: 5, lineCap: .round)
      ).rotationEffect(.degrees(90))
        .animation(.easeOut(duration: 0.2), value: ratio)
      VStack(spacing: 0) {
        Text("CURRENT GEAR").font(.system(size: 10, weight: .bold)).tracking(2.2).foregroundStyle(
          Palette.muted)
        Text(status.gear?.label ?? "—").font(.system(size: 104, weight: .medium, design: .rounded))
          .monospacedDigit().tracking(-6)
          .contentTransition(.numericText()).accessibilityLabel(
            "Observed gear \(status.gear?.label ?? "unknown")")
        Text(status.gear == nil ? "Awaiting Zwift feedback" : "Observed in Zwift")
          .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
      }
      if count > 0 {
        Text("/ \(count)").font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(Palette.muted).offset(y: 111)
      }
    }.frame(width: 236, height: 236)
  }
  private func statusItem(_ title: String, value: String, good: Bool) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.system(size: 9, weight: .bold)).tracking(1.8).foregroundStyle(Palette.muted)
      HStack(spacing: 6) {
        Image(systemName: good ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(
          good ? Palette.lime : Palette.muted)
        Text(value).fontWeight(.medium)
      }.font(.system(size: 12))
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, title == "ZWIFT" ? 0 : 24)
  }
  private var activity: some View {
    VStack(spacing: 10) {
      HStack {
        Text("ACTIVITY").font(.system(size: 9, weight: .bold)).tracking(1.8)
        Spacer()
        Text("\(status.observedChanges) observed changes").font(.system(size: 10)).foregroundStyle(
          Palette.muted)
      }
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(Array(status.events.suffix(40))) { event in
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(
                  event.date,
                  format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(
                    .twoDigits)
                )
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                Text(event.message).font(.system(size: 11)).foregroundStyle(
                  event.level == "observed"
                    ? Palette.lime
                    : event.level == "error" ? Palette.orange : Palette.cream.opacity(0.82)
                )
                .textSelection(.enabled)
              }.id(event.id)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.onChange(of: status.events.last?.id) { _, id in
          if let id { reader.scrollTo(id, anchor: .bottom) }
        }
      }
    }.padding(16).frame(height: 134).background(
      Palette.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
  }
}

private struct ShiftButton: View {
  let direction: ShiftDirection
  let shortcut: String
  let enabled: Bool
  let action: (Bool) -> Void
  let accessibleAction: () -> Void
  @State private var pressed = false
  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: direction == .up ? "arrow.up" : "arrow.down").font(
        .system(size: 28, weight: .medium))
      Text(direction == .up ? "SHIFT UP" : "SHIFT DOWN").font(.system(size: 19, weight: .bold))
        .tracking(0.8)
      Spacer()
      Text(shortcut).font(.system(size: 13, weight: .medium, design: .monospaced)).padding(
        .horizontal, 9
      ).padding(.vertical, 6)
        .background(
          (direction == .up ? Palette.background : Palette.cream).opacity(0.09),
          in: RoundedRectangle(cornerRadius: 6))
    }
    .padding(.horizontal, 24).frame(height: 90)
    .foregroundStyle(direction == .up ? Palette.background : Palette.cream)
    .background(
      direction == .up ? Palette.lime : Palette.raised, in: RoundedRectangle(cornerRadius: 17)
    )
    .brightness(pressed ? 0.08 : 0).scaleEffect(pressed ? 0.985 : 1)
    .opacity(enabled ? 1 : 0.45).contentShape(RoundedRectangle(cornerRadius: 17))
    .gesture(
      DragGesture(minimumDistance: 0).onChanged { _ in
        guard enabled, !pressed else { return }
        pressed = true
        action(true)
      }.onEnded { _ in
        if pressed {
          pressed = false
          action(false)
        }
      }
    )
    .onChange(of: enabled) { _, value in
      if !value && pressed {
        pressed = false
        action(false)
      }
    }
    .onDisappear { if pressed { action(false) } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
    { _ in
      if pressed {
        pressed = false
        action(false)
      }
    }
    .accessibilityElement(children: .ignore).accessibilityLabel(
      direction == .up ? "Shift up" : "Shift down"
    )
    .accessibilityAddTraits(.isButton).accessibilityHint("Press and hold to repeat")
    .accessibilityAction { if enabled { accessibleAction() } }
  }
}

private struct ControlsSettings: View {
  @ObservedObject var model: AppModel
  @State var draft: ZwiftShiftCore.Settings
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack {
        Text("Make it yours.").font(.system(size: 28, weight: .semibold, design: .rounded))
        Spacer()
        Button("Done") { save() }.keyboardShortcut(.defaultAction)
      }
      VStack(alignment: .leading, spacing: 9) {
        HStack {
          Text("Shift repeat interval").fontWeight(.medium)
          Spacer()
          Text("\(draft.repeatMilliseconds) ms").monospacedDigit().foregroundStyle(Palette.lime)
        }
        Slider(
          value: Binding(
            get: { Double(draft.repeatMilliseconds) }, set: { draft.repeatMilliseconds = Int($0) }),
          in: 200...2000, step: 50
        )
        .tint(Palette.lime)
        Text("Applies while holding a button or shortcut, and between CLI shifts.").font(
          .system(size: 12)
        ).foregroundStyle(Palette.muted)
      }
      Divider().overlay(Palette.raised)
      Toggle("Global keyboard shortcuts", isOn: $draft.shortcutsEnabled).toggleStyle(.switch).tint(
        Palette.lime)
      shortcutRow("Shift up", binding: $draft.upShortcut)
      shortcutRow("Shift down", binding: $draft.downShortcut)
      Text(
        "Shortcuts activate when Zwift and your software controller are connected. Ordinary arrow keys remain available."
      )
      .font(.system(size: 12)).foregroundStyle(Palette.muted)
      if let error = error ?? model.shortcutError {
        Text(error).font(.system(size: 12)).foregroundStyle(Palette.orange)
      }
    }.padding(30).frame(width: 560).foregroundStyle(Palette.cream).background(Palette.background)
  }
  private func shortcutRow(_ title: String, binding: Binding<Shortcut>) -> some View {
    HStack(spacing: 10) {
      Text(title).frame(width: 82, alignment: .leading)
      Toggle("⌃", isOn: binding.control)
      Toggle("⌥", isOn: binding.option)
      Toggle("⌘", isOn: binding.command)
      Toggle("⇧", isOn: binding.shift)
      Picker("Key", selection: binding.keyCode) {
        ForEach(Shortcut.keys, id: \.1) { Text($0.0).tag($0.1) }
      }.labelsHidden().frame(width: 80)
    }.toggleStyle(.checkbox).font(.system(size: 13))
  }
  private func save() {
    do {
      try model.save(draft)
      if let failure = model.shortcutError { error = failure } else { dismiss() }
    } catch { self.error = error.localizedDescription }
  }
}

private struct PairingGuide: View {
  let name: String
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text("Connect once. Ride anytime.").font(
        .system(size: 27, weight: .semibold, design: .rounded))
      ForEach(
        Array(
          [
            "Open Zwift’s Paired Devices screen.",
            "Select ‘\(name)’ under Power Source once. This lets Zwift identify the software controller.",
            "Select ‘\(name)’ under Controls.",
            "Return Power Source, Resistance, and Cadence to your actual trainer, then enter a free ride.",
          ].enumerated()), id: \.offset
      ) { index, text in
        HStack(alignment: .top, spacing: 14) {
          Text("\(index + 1)").font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.lime).frame(width: 22)
          Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(
        "Keep both apps on this Mac and your trainer powered on. ZwiftShift remembers its identity for reconnection. In ERG workouts, Zwift determines whether shifting is available."
      )
      .font(.system(size: 12)).foregroundStyle(Palette.muted)
      HStack {
        Spacer()
        Button("Got it") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.padding(32).frame(width: 520).foregroundStyle(Palette.cream).background(Palette.background)
  }
}
