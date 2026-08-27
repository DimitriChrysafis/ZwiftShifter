import Darwin
import Foundation
import ZwiftShifterCore

public enum BridgeState: Sendable, Equatable {
    case ready
    case waiting
    case zwiftNotRunning
    case loading
    case failed(String)

    var title: String {
        switch self {
        case .ready: "Ready"
        case .waiting: "Connecting to Zwift"
        case .zwiftNotRunning: "Zwift is not running"
        case .loading: "Connecting"
        case .failed(let message): message
        }
    }
}

actor ZwiftBridge {
    private let socketPath = "/tmp/zwift-shifter-\(getuid()).sock"
    private var injectedPID: pid_t?

    func state() async -> BridgeState {
        guard let pid = zwiftPID() else {
            injectedPID = nil
            return .zwiftNotRunning
        }
        if let response = socketRequest("S") {
            return decode(response)
        }
        guard clickPeripheralID() != nil else {
            return .failed("Zwift Click session not found")
        }
        if injectedPID != pid {
            guard injectBridge(into: pid) else {
                injectedPID = nil
                return .failed("Could not load bridge")
            }
            injectedPID = pid
        }
        for _ in 0..<50 {
            if let response = socketRequest("S") {
                return decode(response)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .failed("Bridge did not start")
    }

    func shift(_ direction: ShiftDirection) async -> BridgeState {
        let current = await state()
        guard current == .ready else { return current }
        guard let peripheralID = clickPeripheralID() else {
            return .failed("Zwift Click session not found")
        }
        guard let response = socketRequest("\(Character(UnicodeScalar(direction.bridgeCommand)))|\(peripheralID)") else {
            injectedPID = nil
            return .failed("Bridge connection lost")
        }
        return decode(response)
    }

    private func decode(_ byte: UInt8) -> BridgeState {
        switch byte {
        case UInt8(ascii: "R"): .ready
        case UInt8(ascii: "W"): .waiting
        default: .failed("Bridge hook unavailable")
        }
    }

    private func socketRequest(_ message: String) -> UInt8? {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8CString).map { UInt8(bitPattern: $0) }
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let data = Data(message.utf8)
        guard data.withUnsafeBytes({ bytes in
            Darwin.write(descriptor, bytes.baseAddress, data.count)
        }) == data.count else { return nil }
        var response: UInt8 = 0
        guard Darwin.read(descriptor, &response, 1) == 1 else { return nil }
        return response
    }

    private func zwiftPID() -> pid_t? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "ZwiftAppSilicon"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            return text.split(whereSeparator: \Character.isWhitespace).first.flatMap { pid_t($0) }
        } catch {
            return nil
        }
    }

    private func clickPeripheralID() -> String? {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Zwift/Logs/Log.txt")
        guard let data = try? Data(contentsOf: logURL) else { return nil }
        let log = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(
            pattern: #"\[ UUID: ([0-9A-Fa-f-]{36}) \] Zwift Click"#
        ) else { return nil }
        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        guard let match = regex.matches(in: log, range: range).last,
              let valueRange = Range(match.range(at: 1), in: log) else {
            return nil
        }
        return String(log[valueRange])
    }

    private func injectBridge(into pid: pid_t) -> Bool {
        guard let libraryURL = Bundle.main.resourceURL?.appendingPathComponent("ZwiftShiftBridge.dylib") else {
            return false
        }
        let escapedPath = libraryURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "lldb", "-p", "\(pid)",
            "-o", "expr -l objc++ -- @import Darwin",
            "-o", "expr -l objc++ -- (void *)dlopen(\"\(escapedPath)\", 2)",
            "-o", "process detach",
            "-o", "quit"
        ]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let transcript = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return process.terminationStatus == 0 &&
                transcript.contains("Process \(pid) detached") &&
                !transcript.contains("error:")
        } catch {
            return false
        }
    }
}
