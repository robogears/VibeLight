import XCTest
@testable import VibeLight

/// MoonDeckBuddy drives a REAL Windows reboot, so the exact bytes on the wire
/// must match the buddy's API (verified against the plugin's buddyrequests.py,
/// API v8). These lock the auth encoding, the pairing hash, the state mapping,
/// and — via a URLProtocol interceptor — the full restart/pair requests.
final class MoonDeckBuddyClientTests: XCTestCase {

    // MARK: - Pure wire encoding

    func testAuthorizationHeaderIsBasicBase64OfClientID() {
        // "abc" → base64 "YWJj". Header is lowercase "basic", payload is the raw
        // client-id (NOT user:pass).
        XCTAssertEqual(MoonDeckBuddyClient.authorizationHeader(clientID: "abc"), "basic YWJj")
        let uuid = "1E2D3C4B-0000-0000-0000-ABCDEF012345"
        XCTAssertEqual(MoonDeckBuddyClient.authorizationHeader(clientID: uuid),
                       "basic " + Data(uuid.utf8).base64EncodedString())
    }

    func testPairingHashIsBase64OfClientIDPlusPIN() {
        // base64("abc" + "1234") = base64("abc1234")
        XCTAssertEqual(MoonDeckBuddyClient.pairingHash(clientID: "abc", pin: "1234"),
                       Data("abc1234".utf8).base64EncodedString())
    }

    func testPairStateRawMapping() {
        XCTAssertEqual(MoonDeckBuddyClient.PairState(rawValue: 0), .paired)
        XCTAssertEqual(MoonDeckBuddyClient.PairState(rawValue: 1), .pairing)
        XCTAssertEqual(MoonDeckBuddyClient.PairState(rawValue: 2), .notPaired)
        XCTAssertNil(MoonDeckBuddyClient.PairState(rawValue: 3))
    }

    // MARK: - Full request/response (URLProtocol interceptor)

    func testRestartSendsCorrectMethodPathHeaderAndBody() async throws {
        let client = MoonDeckBuddyClient(configuration: MockURLProtocol.config())
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.scheme, "https")
            XCTAssertEqual(req.url?.host, "192.0.2.10")
            XCTAssertEqual(req.url?.port, 59999)
            XCTAssertEqual(req.url?.path, "/restartHost")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "basic YWJj")  // clientID "abc"
            let body = MockURLProtocol.body(of: req)
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(json["delay"] as? Int, 5)
            return (200, Data(#"{"result": true}"#.utf8))
        }
        try await client.restart(host: "192.0.2.10", port: 59999, clientID: "abc", delaySeconds: 5)
    }

    func testRestartClampsDelayInto1To30() async throws {
        let client = MoonDeckBuddyClient(configuration: MockURLProtocol.config())
        MockURLProtocol.handler = { req in
            let json = try! JSONSerialization.jsonObject(with: MockURLProtocol.body(of: req)) as! [String: Any]
            XCTAssertEqual(json["delay"] as? Int, 30, "delay above the buddy's 30s cap must clamp")
            return (200, Data(#"{"result": true}"#.utf8))
        }
        try await client.restart(host: "h", port: 1, clientID: "abc", delaySeconds: 999)
    }

    func testRestart401MapsToUnauthorized() async {
        let client = MoonDeckBuddyClient(configuration: MockURLProtocol.config())
        MockURLProtocol.handler = { _ in (401, Data()) }
        do {
            try await client.restart(host: "h", port: 1, clientID: "abc")
            XCTFail("expected unauthorized")
        } catch let e as MoonDeckBuddyClient.MDError {
            XCTAssertEqual(e, .unauthorized)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testRestartResultFalseThrowsRejected() async {
        let client = MoonDeckBuddyClient(configuration: MockURLProtocol.config())
        MockURLProtocol.handler = { _ in (200, Data(#"{"result": false}"#.utf8)) }
        do {
            try await client.restart(host: "h", port: 1, clientID: "abc")
            XCTFail("expected rejected")
        } catch let e as MoonDeckBuddyClient.MDError {
            XCTAssertEqual(e, .restartRejected)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testPairSendsIdAndHashedId() async throws {
        let client = MoonDeckBuddyClient(configuration: MockURLProtocol.config())
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/pair")
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "/pair is unauthenticated")
            let json = try! JSONSerialization.jsonObject(with: MockURLProtocol.body(of: req)) as! [String: Any]
            XCTAssertEqual(json["id"] as? String, "abc")
            XCTAssertEqual(json["hashed_id"] as? String, MoonDeckBuddyClient.pairingHash(clientID: "abc", pin: "1234"))
            return (200, Data("{}".utf8))
        }
        try await client.startPairing(host: "h", port: 1, clientID: "abc", pin: "1234")
    }

    func testPairStateParsesStateInt() async throws {
        let client = MoonDeckBuddyClient(configuration: MockURLProtocol.config())
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/pairingState/abc")
            return (200, Data(#"{"state": 0}"#.utf8))
        }
        let state = try await client.pairState(host: "h", port: 1, clientID: "abc")
        XCTAssertEqual(state, .paired)
    }

    func testApiVersionMismatchThrows() async {
        let client = MoonDeckBuddyClient(configuration: MockURLProtocol.config())
        MockURLProtocol.handler = { _ in (200, Data(#"{"version": 7}"#.utf8)) }
        do {
            try await client.checkReachable(host: "h", port: 1)
            XCTFail("expected version mismatch")
        } catch let e as MoonDeckBuddyClient.MDError {
            XCTAssertEqual(e, .apiVersionMismatch(7))
        } catch { XCTFail("wrong error: \(error)") }
    }
}

/// Intercepts URLSession requests so tests can assert the exact wire format and
/// return canned responses without a network.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    static func config() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return c
    }

    /// URLProtocol strips the httpBody into a stream; recover the bytes for asserts.
    static func body(of req: URLRequest) -> Data {
        if let b = req.httpBody { return b }
        guard let stream = req.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
