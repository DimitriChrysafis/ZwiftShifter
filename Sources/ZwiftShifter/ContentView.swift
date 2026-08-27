import SwiftUI
import ZwiftShifterCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 5) {
                Text("Zwift Shifter")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                statusView
            }

            HStack(spacing: 16) {
                shiftButton(
                    title: "SHIFT LEFT",
                    subtitle: "Easier",
                    symbol: "arrow.left",
                    direction: .easier
                )
                shiftButton(
                    title: "SHIFT RIGHT",
                    subtitle: "Harder",
                    symbol: "arrow.right",
                    direction: .harder
                )
            }

            VStack(spacing: 4) {
                Text("Last command: \(model.lastCommand)")
                    .font(.callout.weight(.medium))
                Text("Commands sent: \(model.shiftCount)  •  Keyboard: ← / →")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 460, height: 280)
    }

    private var statusView: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(model.state.title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.state != .ready {
                Button("Retry") { model.reconnect() }
                    .buttonStyle(.link)
            }
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .ready: .green
        case .loading, .waiting: .orange
        case .zwiftNotRunning, .failed: .red
        }
    }

    private func shiftButton(
        title: String,
        subtitle: String,
        symbol: String,
        direction: ShiftDirection
    ) -> some View {
        Button { model.shift(direction) } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .bold))
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 105)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.state != .ready)
        .keyboardShortcut(direction == .easier ? .leftArrow : .rightArrow, modifiers: [])
    }
}
