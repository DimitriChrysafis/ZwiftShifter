import Foundation

/// A quick click must still be a complete press/release transition. Cancellation
/// and transport errors also release the button; no caller can leave it pressed.
@MainActor enum ButtonPulse {
  static let milliseconds = 120

  static func perform(
    _ direction: ShiftDirection,
    send: (ShiftDirection?) throws -> Void,
    sleep: (Duration) async throws -> Void = {
      try await Task.sleep(for: $0, tolerance: .milliseconds(5))
    }
  ) async throws {
    defer { try? send(nil) }
    try send(direction)
    try await sleep(.milliseconds(milliseconds))
    try Task.checkCancellation()
  }
}
