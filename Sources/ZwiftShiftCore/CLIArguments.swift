import Foundation

public struct CLIArguments: Equatable {
  public enum Command: Equatable {
    case status, diagnostics
    case shift(ShiftDirection, Int)
    case serve, help, version
  }
  public let command: Command
  public let json: Bool
  public init(_ arguments: [String]) throws {
    json = arguments.contains("--json")
    let args = arguments.filter { $0 != "--json" }
    guard let verb = args.first else {
      command = .help
      return
    }
    if verb == "up" || verb == "down" {
      let count: Int
      if args.count == 1 {
        count = 1
      } else if args.count == 3, args[1] == "--count", let value = Int(args[2]),
        (1...100).contains(value)
      {
        count = value
      } else {
        throw ShiftError.message("Usage: zwiftshift \(verb) [--count 1…100] [--json]")
      }
      command = .shift(ShiftDirection(rawValue: verb)!, count)
      return
    }
    guard args.count == 1 else {
      throw ShiftError.message("Unexpected arguments. Run zwiftshift --help.")
    }
    switch verb {
    case "status": command = .status
    case "diagnostics": command = .diagnostics
    case "serve": command = .serve
    case "--help", "help", "-h": command = .help
    case "--version": command = .version
    default: throw ShiftError.message("Unknown command ‘\(verb)’. Run zwiftshift --help.")
    }
  }
}
