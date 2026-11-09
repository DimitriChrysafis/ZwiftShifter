import Foundation
import XCTest

@testable import ZwiftShiftCore

final class PhoneHTTPTests: XCTestCase {
  func testFragmentedRequestAndBoundedFraming() throws {
    var decoder = HTTPRequestDecoder()
    XCTAssertNil(try decoder.append(Data("POST /api/shift HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n".utf8)))
    XCTAssertNil(try decoder.append(Data("\r\n{".utf8)))
    let request = try XCTUnwrap(decoder.append(Data("}".utf8)))
    XCTAssertEqual(request.target, "/api/shift")
    XCTAssertEqual(request.body, Data("{}".utf8))
    for headers in [
      "Content-Length: 2\r\nContent-Length: 2\r\n",
      "Transfer-Encoding: chunked\r\n", "Content-Length: 999999\r\n",
      "Content-Length: -2\r\n", "Host: evil.example\r\n", "Bad Header: value\r\n",
    ] {
      var invalid = HTTPRequestDecoder()
      XCTAssertThrowsError(try invalid.append(Data((
        "POST /api/shift HTTP/1.1\r\nHost: localhost\r\n" + headers + "\r\n").utf8)))
    }
    var oversized = HTTPRequestDecoder()
    XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: 8193)))
    var pipelined = HTTPRequestDecoder()
    XCTAssertThrowsError(try pipelined.append(Data(
      "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nGET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)))
  }
  func testNgrokOutputExtractsOnlyEndpointAndErrorCode() throws {
    let event = NgrokLogEvent(Data(#"{"msg":"started tunnel","url":"https://example.ngrok-free.app"}"#.utf8))
    XCTAssertEqual(event.publicURL, "https://example.ngrok-free.app/")
    for value in ["http://example.ngrok.app", "https://user:secret@example.com/", "file:///private/data"] {
      let bytes = try JSONSerialization.data(withJSONObject: ["msg": "started tunnel", "url": value])
      XCTAssertNil(NgrokLogEvent(bytes).publicURL)
    }
    XCTAssertEqual(NgrokLogEvent(Data("authentication failed ERR_NGROK_4018 secret".utf8)).errorCode,
      "ERR_NGROK_4018")
  }
}

@MainActor final class PhoneRouterTests: XCTestCase {
  private let token = String(repeating: "a", count: 64)
  private func request(
    _ target: String, method: String = "GET", auth: String? = nil,
    body: Data = Data(), extra: [String: String] = [:]
  ) -> HTTPRequest {
    var headers = ["host": "localhost", "content-type": "application/json"]
    if let auth { headers["authorization"] = "Bearer " + auth }
    headers.merge(extra) { _, new in new }
    return HTTPRequest(method: method, target: target, headers: headers, body: body)
  }
  private func command(id: String = String(repeating: "b", count: 32), offset: Double = 2000) throws -> Data {
    try JSONEncoder().encode(PhoneCommand(id: id, direction: .up,
      expiresAt: Date().timeIntervalSince1970 * 1000 + offset))
  }
  private func response(_ router: PhoneRouter, _ request: HTTPRequest) -> HTTPResponse? {
    var result: HTTPResponse?
    router.handle(request) { result = $0 }
    return result
  }
  func testAuthenticationOriginAndNoPrivateStateLeak() throws {
    var calls = 0
    let router = PhoneRouter(token: token, readStatus: { ServiceStatus(settings: Settings()) },
      shift: { _, _ in calls += 1 })
    let root = try XCTUnwrap(response(router, request("/")))
    XCTAssertEqual(root.code, 200)
    XCTAssertTrue(String(decoding: root.body, as: UTF8.self).contains("Shift up"))
    XCTAssertFalse(String(decoding: root.body, as: UTF8.self).contains(token))
    XCTAssertTrue(String(decoding: root.encoded(), as: UTF8.self).contains("frame-ancestors 'none'"))
    XCTAssertEqual(response(router, request("/api/status"))?.code, 401)
    XCTAssertEqual(response(router, request("/api/shift", method: "POST", auth: "wrong", body: try command()))?.code, 401)
    XCTAssertEqual(response(router, request("/api/shift", method: "POST", auth: token,
      body: try command(), extra: ["origin": "https://evil.example"]))?.code, 403)
    XCTAssertEqual(calls, 0)
    let status = try XCTUnwrap(response(router, request("/api/status", auth: token)))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: status.body) as? [String: Any])
    XCTAssertNil(object["settings"])
    XCTAssertNil(object["events"])
    XCTAssertNil(object["phone"])
    XCTAssertNotNil(object["serverTime"])
    for path in ["/api/settings", "/../phone.json", "/phone.json", "/control.sock"] {
      XCTAssertEqual(response(router, request(path, auth: token))?.code, 404)
    }
  }
  func testExpiredMalformedAndFutureCommandsNeverShift() throws {
    var calls = 0
    let router = PhoneRouter(token: token, readStatus: { ServiceStatus(settings: Settings()) },
      shift: { _, _ in calls += 1 })
    for offset in [-1.0, 30_000] {
      XCTAssertEqual(response(router, request("/api/shift", method: "POST", auth: token,
        body: try command(offset: offset)))?.code, 409)
    }
    XCTAssertEqual(response(router, request("/api/shift", method: "POST", auth: token,
      body: Data("{}".utf8)))?.code, 400)
    XCTAssertEqual(response(router, request("/api/shift", method: "POST", auth: token,
      body: try command(), extra: ["content-type": "text/plain"]))?.code, 400)
    XCTAssertEqual(calls, 0)
  }
  func testDuplicateRequestsAreNeverReexecutedAndRotationRevokesOldLinks() throws {
    var calls = 0
    var finish: ((RPCResponse) -> Void)?
    let router = PhoneRouter(token: token, readStatus: { ServiceStatus(settings: Settings()) },
      shift: { _, callback in calls += 1; finish = callback })
    let press = request("/api/shift", method: "POST", auth: token, body: try command())
    var first: HTTPResponse?
    router.handle(press) { first = $0 }
    XCTAssertEqual(response(router, press)?.code, 409)
    XCTAssertEqual(calls, 1)
    finish?(RPCResponse(ok: true, message: "Confirmed.", confirmed: true))
    XCTAssertEqual(first?.code, 200)
    XCTAssertEqual(response(router, press)?.body, first?.body)
    XCTAssertEqual(calls, 1)
    router.resetToken(String(repeating: "c", count: 64))
    XCTAssertEqual(response(router, press)?.code, 401)
    XCTAssertEqual(response(router, request("/api/status", auth: String(repeating: "c", count: 64)))?.code, 200)
  }
  func testRateLimitBoundsAcceptedCommands() throws {
    var calls = 0
    let router = PhoneRouter(token: token, readStatus: { ServiceStatus(settings: Settings()) },
      shift: { _, callback in
        calls += 1
        callback(RPCResponse(ok: false, message: "Offline."))
      })
    for i in 0..<10 {
      let result = response(router, request("/api/shift", method: "POST", auth: token,
        body: try command(id: String(format: "%032x", i))))
      XCTAssertEqual(result?.code, i < 8 ? 200 : 429)
    }
    XCTAssertEqual(calls, 8)
  }
  func testTokenStorageStablePrivateAndNgrokOverlayContainsNoCredential() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = RuntimePaths(directory: directory)
    let make = { try PhoneControl(paths: paths,
      readStatus: { ServiceStatus(settings: Settings()) }, shift: { _, _ in XCTFail("No shift expected") }) }
    let first = try make()
    let original = try XCTUnwrap(first.link(for: "http://localhost:54874/"))
    let restored = try make()
    XCTAssertEqual(restored.link(for: "http://localhost:54874/"), original)
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("phone.json").path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    try restored.resetAccess()
    XCTAssertNotEqual(restored.link(for: "http://localhost:54874/"), original)
    XCTAssertEqual(try NgrokTunnel.overlay(version: "3"),
      "version: \"3\"\nagent:\n  web_addr: false\n  console_ui: false\n  update_check: false\n")
    XCTAssertFalse(try NgrokTunnel.overlay(version: "2").contains("authtoken"))
    XCTAssertThrowsError(try NgrokTunnel.overlay(version: "9"))
  }
  func testRealHTTPTransportAuthenticationSharedHandlerAndRestart() async throws {
    var calls: [ShiftDirection] = []
    let router = PhoneRouter(token: token, readStatus: { ServiceStatus(settings: Settings()) },
      shift: { direction, completion in
        calls.append(direction)
        completion(RPCResponse(ok: true, message: "Test handler only.", confirmed: true))
      })
    let server = PhoneHTTPServer()
    server.handler = { request, completion in router.handle(request, completion: completion) }
    defer { server.stop() }
    for _ in 0..<2 {
      try server.start(port: 0)
      for _ in 0..<100 where server.boundPort == nil { try await Task.sleep(for: .milliseconds(10)) }
      let port = try XCTUnwrap(server.boundPort)
      let url = URL(string: "http://127.0.0.1:\(port)/api/shift")!
      var req = URLRequest(url: url, timeoutInterval: 3)
      req.httpMethod = "POST"
      req.httpBody = try command(id: UUID().uuidString.lowercased())
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let (_, denied) = try await URLSession.shared.data(for: req)
      XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)
      req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
      let (body, accepted) = try await URLSession.shared.data(for: req)
      XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
      let result = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(result["confirmed"] as? Bool, true)
      XCTAssertEqual((accepted as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
      server.stop()
      XCTAssertNil(server.boundPort)
    }
    XCTAssertEqual(calls, [.up, .up])
  }
}
