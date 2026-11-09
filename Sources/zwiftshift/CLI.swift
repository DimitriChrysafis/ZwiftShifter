import Darwin
import Foundation
import ZwiftShiftCore

@main struct ZwiftShiftCLI {
  @MainActor static func main() {
    if CommandLine.arguments.dropFirst().first == "__ngrok" {
      exit(NgrokWorker.run(Array(CommandLine.arguments.dropFirst(2))))
    }
    do {
      let args = try CLIArguments(Array(CommandLine.arguments.dropFirst()))
      let request: RPCRequest
      switch args.command {
      case .help:
        print(
          """
          zwiftshift — native local-network shifting for Zwift

          zwiftshift status [--json]
          zwiftshift up [--count 1…100] [--json]
          zwiftshift down [--count 1…100] [--json]
          zwiftshift diagnostics
          zwiftshift serve

          Open ZwiftShift.app first, or use ‘serve’ for a foreground service.
          Shift commands wait for confirmation in Zwift’s own gear log.
          Exit codes: 0 success, 1 service/usage error, 2 unconfirmed shift.
          ZWIFTSHIFT_HOME overrides the private runtime directory.
          """)
        return
      case .version:
        print("ZwiftShift 1.0.0")
        return
      case .serve:
        let service = try ShiftService()
        try service.start()
        print(
          "ZwiftShift listening. Pair ‘\(service.status.settings.deviceName)’ in Zwift. Ctrl-C stops cleanly."
        )
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
          signal(number, SIG_IGN)
          let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
          source.setEventHandler {
            MainActor.assumeIsolated { service.stop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
          }
          source.resume()
          sources.append(source)
        }
        withExtendedLifetime((service, sources)) { RunLoop.main.run() }
        return
      case .status: request = RPCRequest(command: "status")
      case .diagnostics: request = RPCRequest(command: "diagnostics")
      case .shift(let direction, let count):
        request = RPCRequest(command: "shift", direction: direction, count: count)
      }
      let response = try RPCClient.request(request)
      if args.json || args.command == .diagnostics {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(response), as: UTF8.self))
      } else if args.command == .status, let status = response.status {
        print("Zwift: \(status.zwiftRunning ? "running" : "not running")")
        print(
          "Controller: \(status.state)\(status.paired ? " · paired under Controls" : " · pairing needed")"
        )
        print("Gear: \(status.gear?.label ?? "unknown") · observed in Zwift’s log")
        print(
          "Trainer virtual shifting: \(status.virtualShiftingEnabled ? "enabled in Zwift" : "not reported active")"
        )
        if status.controllerAsPowerSource {
          print(
            "Power source: ZwiftShift selected · select your trainer; keep ZwiftShift under Controls"
          )
        }
        print("Backend: \(status.backend)")
        if let phone = status.phone {
          print("Phone controls: \(phone.publicURL ?? phone.localURLs.first ?? phone.state)")
          print("Open Phone controls in the app for the private link or QR code.")
        }
        print(
          "Repeat: \(status.settings.repeatMilliseconds) ms · shortcuts \(status.settings.upShortcut.label) / \(status.settings.downShortcut.label)"
        )
      } else {
        print(response.message)
      }
      if !response.ok { exit(2) }
    } catch {
      FileHandle.standardError.write(Data("zwiftshift: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
