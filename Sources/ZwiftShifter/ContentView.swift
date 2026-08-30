import SwiftUI
import ZwiftShifterCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 28) {
            Circle()
                .fill(statusColor)
                .frame(width: 18, height: 18)

            Button { model.shift(.easier) } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.state != .ready)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button { model.shift(.harder) } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.state != .ready)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .padding(24)
        .frame(width: 320, height: 120)
    }

    private var statusColor: Color {
        model.state == .ready ? .green : .red
    }
}
