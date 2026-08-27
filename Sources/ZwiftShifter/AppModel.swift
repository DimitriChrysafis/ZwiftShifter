import Foundation
import SwiftUI
import ZwiftShifterCore

@MainActor
final class AppModel: ObservableObject {
    @Published var state: BridgeState = .loading
    @Published var lastCommand = "None"
    @Published var shiftCount = 0
    @Published var isSending = false

    private let bridge = ZwiftBridge()
    private var monitorTask: Task<Void, Never>?

    init() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let newState = await bridge.state()
                state = newState
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    deinit {
        monitorTask?.cancel()
    }

    func shift(_ direction: ShiftDirection) {
        isSending = true
        Task {
            let newState = await bridge.shift(direction)
            state = newState
            if newState == .ready {
                shiftCount += 1
                lastCommand = direction == .easier ? "Shift left — easier" : "Shift right — harder"
            }
            isSending = false
        }
    }

    func reconnect() {
        state = .loading
        Task { state = await bridge.state() }
    }
}
