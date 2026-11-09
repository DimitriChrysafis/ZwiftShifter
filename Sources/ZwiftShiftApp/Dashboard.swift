import AppKit
import SwiftUI
import ZwiftShiftCore

struct Dashboard: View {
  @ObservedObject var model: AppModel
  private var status: ServiceStatus { model.status }

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 2) {
        Text("Gear").font(.system(size: 12)).foregroundStyle(.secondary)
        Text(status.gear?.label ?? "—")
          .font(.system(size: 88, weight: .regular)).monospacedDigit()
          .minimumScaleFactor(0.5).lineLimit(1)
          .frame(height: 104)
          .accessibilityLabel("Gear reported by Zwift")
          .accessibilityValue(status.gear?.label ?? "Unknown")
          .accessibilityIdentifier("observed-gear")
        Text(gearCount).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .help("The last gear reported by Zwift. Trainer readiness is shown below.")

      HStack(spacing: 10) {
        shiftControl(.down, shortcut: status.settings.downShortcut.label)
        shiftControl(.up, shortcut: status.settings.upShortcut.label)
      }

      HStack {
        Button {
          model.panel = model.shortcutError == nil ? .connection : .settings
        } label: {
          HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 5, height: 5)
            Text(connectionLabel).font(.system(size: 12))
          }
          .foregroundStyle(.secondary)
          .frame(minHeight: 24)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Connection details and pairing help")
        .accessibilityIdentifier("connection-status")
        Spacer()
        Menu {
          Button("Settings…") { model.panel = .settings }
          Button("Connection…") { model.panel = .connection }
          Button("Activity…") { model.panel = .activity }
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 15))
            .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize().foregroundStyle(.secondary)
        .help("Settings, connection, and activity")
        .accessibilityLabel("More")
        .accessibilityIdentifier("more-menu")
      }
    }
    .padding(20)
    .frame(width: 380, height: 320)
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(item: $model.panel) { panel in
      switch panel {
      case .settings: ControlsSettings(model: model, draft: status.settings)
      case .connection: ConnectionDetails(model: model)
      case .activity: ActivityView(model: model)
      }
    }
  }

  private var gearCount: String {
    guard let gear = status.gear, gear.frontCount == 1, let count = gear.rearCount else {
      return " "
    }
    return "of \(count)"
  }

  private var connectionLabel: String {
    if model.fatalError != nil { return "Unable to start" }
    if model.shortcutError != nil { return "Shortcut unavailable" }
    if !status.zwiftRunning { return "Open Zwift to connect" }
    if status.controllerAsPowerSource { return "Select your trainer" }
    if !status.canShift { return "Pair with Zwift" }
    if !status.virtualShiftingEnabled { return "Trainer not ready" }
    return "Connected"
  }

  private var statusColor: Color {
    if model.fatalError != nil || model.shortcutError != nil { return .orange }
    if status.controllerAsPowerSource || (status.canShift && !status.virtualShiftingEnabled) {
      return .orange
    }
    return status.canShift ? .green : Color(nsColor: .tertiaryLabelColor)
  }

  private func shiftControl(_ direction: ShiftDirection, shortcut: String) -> some View {
    VStack(spacing: 7) {
      ShiftButton(
        direction: direction, enabled: status.canShift,
        action: { model.press(direction, down: $0) },
        accessibleAction: { model.single(direction) })
      Text(status.settings.shortcutsEnabled ? shortcut : " ")
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }.frame(maxWidth: .infinity)
  }
}

private struct ShiftButton: View {
  let direction: ShiftDirection
  let enabled: Bool
  let action: (Bool) -> Void
  let accessibleAction: () -> Void
  @State private var pressed = false
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: direction == .up ? "arrow.up" : "arrow.down")
        .font(.system(size: 15, weight: .medium))
      Text(direction == .up ? "Shift up" : "Shift down")
        .font(.system(size: 14, weight: .medium))
    }
    .frame(maxWidth: .infinity).frame(height: 52)
    .foregroundStyle(enabled ? Color.primary : Color.secondary)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .fill(Color.primary.opacity(enabled ? (pressed ? 0.10 : hovering ? 0.035 : 0) : 0))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
    }
    .opacity(enabled ? 1 : 0.55)
    .contentShape(RoundedRectangle(cornerRadius: 7))
    .onHover { hovering = $0 }
    .gesture(
      DragGesture(minimumDistance: 0).onChanged { _ in
        guard enabled, !pressed else { return }
        pressed = true
        action(true)
      }.onEnded { _ in release() }
    )
    .onChange(of: enabled) { _, value in if !value { release() } }
    .onDisappear { release() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
    {
      _ in release()
    }
    .disabled(!enabled)
    .help("Press and hold to repeat")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(direction == .up ? "Shift up" : "Shift down")
    .accessibilityIdentifier("shift-\(direction.rawValue)")
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Press and hold to repeat")
    .accessibilityAction { if enabled { accessibleAction() } }
  }

  private func release() {
    guard pressed else { return }
    pressed = false
    action(false)
  }
}

private struct ControlsSettings: View {
  @ObservedObject var model: AppModel
  @State var draft: ZwiftShiftCore.Settings
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Settings").font(.system(size: 17, weight: .semibold))
      VStack(spacing: 8) {
        HStack {
          Text("Repeat interval")
          Spacer()
          Text("\(draft.repeatMilliseconds) ms").monospacedDigit().foregroundStyle(.secondary)
        }
        Slider(
          value: Binding(
            get: { Double(draft.repeatMilliseconds) }, set: { draft.repeatMilliseconds = Int($0) }),
          in: 200...2000, step: 50
        ).accessibilityLabel("Repeat interval")
        Text("Time between shifts while holding a control.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        Toggle("Global shortcuts", isOn: $draft.shortcutsEnabled)
        VStack(spacing: 12) {
          shortcutRow("Shift up", binding: $draft.upShortcut)
          shortcutRow("Shift down", binding: $draft.downShortcut)
        }.disabled(!draft.shortcutsEnabled)
      }
      if let error = error ?? model.shortcutError {
        Text(error).font(.system(size: 12)).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") { save() }.keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("save-settings")
      }
    }
    .font(.system(size: 13)).padding(24).frame(width: 420)
  }

  private func shortcutRow(_ title: String, binding: Binding<Shortcut>) -> some View {
    HStack(spacing: 8) {
      Text(title).frame(width: 65, alignment: .leading)
      Toggle("⌃", isOn: binding.control).help("Control").accessibilityLabel("\(title) Control")
      Toggle("⌥", isOn: binding.option).help("Option").accessibilityLabel("\(title) Option")
      Toggle("⌘", isOn: binding.command).help("Command").accessibilityLabel("\(title) Command")
      Toggle("⇧", isOn: binding.shift).help("Shift").accessibilityLabel("\(title) Shift")
      Picker("\(title) key", selection: binding.keyCode) {
        ForEach(Shortcut.keys, id: \.1) { Text($0.0).tag($0.1) }
      }.labelsHidden().frame(width: 60)
    }.toggleStyle(.checkbox).font(.system(size: 12))
  }

  private func save() {
    do {
      try model.save(draft)
      if let failure = model.shortcutError { error = failure } else { dismiss() }
    } catch { self.error = error.localizedDescription }
  }
}

private struct ConnectionDetails: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  private var status: ServiceStatus { model.status }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Connection").font(.system(size: 17, weight: .semibold))
      VStack(spacing: 8) {
        LabeledContent("Zwift", value: status.zwiftRunning ? "Running" : "Not running")
        LabeledContent("Controls", value: status.canShift ? "Connected" : "Not paired")
        LabeledContent(
          "Virtual shifting", value: status.virtualShiftingEnabled ? "Enabled" : "Not enabled")
        LabeledContent("Connection", value: "Local network")
      }
      if status.controllerAsPowerSource {
        Text(
          "ZwiftShift is selected as Power Source. Select your trainer there and under Resistance. Keep ZwiftShift under Controls."
        )
        .fixedSize(horizontal: false, vertical: true)
      } else if !status.virtualShiftingEnabled {
        Text(
          "Zwift needs a compatible trainer to enable virtual shifting. The gear readout can respond to input while trainer shifting is unavailable."
        )
        .fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      Text("Pair with Zwift").fontWeight(.medium)
      VStack(alignment: .leading, spacing: 10) {
        step(
          1,
          "Open Zwift’s Paired Devices screen and select ‘\(status.settings.deviceName)’ under Controls."
        )
        step(
          2,
          "If it is missing, select it under Power Source briefly so Zwift discovers it, then select it under Controls."
        )
        step(
          3,
          "Use your actual trainer for Power Source, Resistance, and Cadence before riding. Enable virtual shifting in Zwift’s settings."
        )
      }
      Text(
        "Virtual shifting needs a supported trainer connection and firmware. It is unavailable in ERG mode."
      )
      .font(.system(size: 11)).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let error = model.fatalError ?? status.lastError {
        Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        if model.fatalError != nil { Button("Retry connection") { model.start() } }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.font(.system(size: 13)).padding(24).frame(width: 440)
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number).").foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ActivityView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Activity").font(.system(size: 17, weight: .semibold))
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      Divider()
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.status.events.suffix(80))) { event in
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(
                  event.date,
                  format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(
                    .twoDigits)
                )
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text(event.message).font(.system(size: 12))
                  .foregroundStyle(event.level == "error" ? Color.red : Color.primary)
                  .textSelection(.enabled)
              }.id(event.id)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
          if let id = model.status.events.last?.id { reader.scrollTo(id, anchor: .bottom) }
        }
        .onChange(of: model.status.events.last?.id) { _, id in
          if let id { reader.scrollTo(id, anchor: .bottom) }
        }
      }
    }.padding(24).frame(width: 520, height: 360)
  }
}
