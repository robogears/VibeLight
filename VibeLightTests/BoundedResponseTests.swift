import XCTest
@testable import VibeLight

/// End-to-end coverage for the 16 MB response cap, driven through the REAL
/// request path — `HostAPIClient.serverInfo` → `boundedData` → the mTLS
/// delegate's chunk accumulation — against a local HTTPS server.
///
/// The cap used to be a check performed *after* `session.data(for:)` had already
/// buffered the whole body, so a host that lied about (or omitted)
/// Content-Length could make the app hold hundreds of megabytes before the
/// check ran. These tests exist because the fix replaced the convenience API
/// with a hand-driven data task: if that rewiring were wrong, every host request
/// would break, and `testNormalResponseStillParses` is what catches it.
final class BoundedResponseTests: XCTestCase {

    private var server: LocalTLSServer!

    override func setUpWithError() throws {
        try XCTSkipIf(LocalTLSServer.python3 == nil, "python3 unavailable")
        server = try LocalTLSServer()
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    /// A host record pointing at the local server. Unpaired (no pinned cert) so
    /// the delegate takes the trust-on-first-use path and accepts the
    /// self-signed cert — exactly what a real "saved but not yet paired" host does.
    private func host() -> StreamHost {
        StreamHost(id: "test-host", name: "Local Test Host",
                   localAddress: nil, localPort: 47989,
                   remoteAddress: nil, remotePort: 47989,
                   // serverInfo dials (port - 5), so advertise base = actual + 5.
                   manualAddress: "127.0.0.1", manualPort: server.port + 5,
                   macAddress: nil, serverCertPEM: nil, apps: [])
    }

    private func client() -> HostAPIClient {
        let identity = IdentityStore.resolve(moonlightIdentity: nil)
        return HostAPIClient(identityProvider: ClientIdentityProvider(identity: identity))
    }

    // MARK: - The path must still work

    func testNormalResponseStillParses() async throws {
        server.serve(Data("""
            <?xml version="1.0"?>
            <root status_code="200"><hostname>Test PC</hostname>\
            <currentgame>0</currentgame><PairStatus>1</PairStatus>\
            <ServerCodecModeSupport>259</ServerCodecModeSupport></root>
            """.utf8), declaredLength: true)

        let (info, address) = try await client().serverInfo(for: host())
        XCTAssertEqual(info.hostname, "Test PC")
        XCTAssertEqual(info.serverCodecModeSupport, 259)
        XCTAssertTrue(info.pairStatus)
        XCTAssertEqual(address, "127.0.0.1")
    }

    // MARK: - The cap

    func testOversizedBodyWithHonestContentLengthIsRejected() async throws {
        // 20 MB, declared. Should be refused from the response headers alone,
        // before any body byte is read.
        server.serve(Data(repeating: 0x41, count: 20 * 1024 * 1024), declaredLength: true)

        do {
            _ = try await client().serverInfo(for: host())
            XCTFail("a 20 MB response must be rejected")
        } catch {
            XCTAssertTrue("\(error)".contains("too large"), "unexpected error: \(error)")
        }
        // The property that matters, and the one the OLD code failed: a declared
        // oversize is refused from the headers, so the body is never served at
        // all. Asserting only the error message would pass against the previous
        // implementation, which buffered all 20 MB and complained afterwards.
        let served = server.bytesServed() ?? 0
        XCTAssertLessThan(served, 1 * 1024 * 1024,
                          "declared oversize must be refused before the body is read; server sent \(served) bytes")
    }

    func testOversizedBodyWithNoContentLengthIsRejectedMidTransfer() async throws {
        // Chunked, no declared length — the case the old post-hoc check could
        // not catch, because the body was fully buffered before it ran.
        server.serve(Data(repeating: 0x42, count: 20 * 1024 * 1024), declaredLength: false)

        do {
            _ = try await client().serverInfo(for: host())
            XCTFail("an undeclared 20 MB response must be rejected")
        } catch {
            XCTAssertTrue("\(error)".contains("too large"), "unexpected error: \(error)")
        }
        // Killed MID-transfer: the server must not have managed to send the
        // whole 20 MB. The old post-hoc check consumed every byte first, so this
        // assertion — not the error message — is what proves the fix.
        let served = server.bytesServed() ?? Int.max
        XCTAssertLessThan(served, 20 * 1024 * 1024,
                          "transfer must be aborted before the full body is served; server sent \(served) bytes")
    }

    func testResponseJustUnderTheCapIsAccepted() async throws {
        // 8 MB of XML: comfortably under 16 MB, and proves the cap does not fire
        // early on a large-but-legal body (the box-art path can be chunky).
        let filler = String(repeating: "x", count: 8 * 1024 * 1024)
        server.serve(Data("<root status_code=\"200\"><hostname>Big</hostname><pad>\(filler)</pad></root>".utf8),
                     declaredLength: true)

        let (info, _) = try await client().serverInfo(for: host())
        XCTAssertEqual(info.hostname, "Big")
    }
}

// MARK: - Local HTTPS server

/// A throwaway self-signed HTTPS server, so the tests exercise the real TLS
/// delegate rather than a URLProtocol stub (a stub would bypass the very
/// callbacks under test).
final class LocalTLSServer {
    static let python3: String? = {
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }()

    let port: Int
    private var process: Process?
    private let dir: URL
    private let payloadURL: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibelight-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        payloadURL = dir.appendingPathComponent("payload.bin")
        port = Int.random(in: 45000...45999)

        // Self-signed cert for 127.0.0.1 — the client pins on first sight
        // (unpaired TOFU), so its contents don't matter, only that TLS completes.
        let pem = dir.appendingPathComponent("server.pem")
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                             "-keyout", pem.path, "-out", pem.path.replacingOccurrences(of: ".pem", with: ".crt"),
                             "-days", "1", "-subj", "/CN=127.0.0.1"]
        openssl.standardOutput = Pipe(); openssl.standardError = Pipe()
        try openssl.run(); openssl.waitUntilExit()
        // openssl -keyout and -out to separate files; concatenate for ssl module.
        let crt = try Data(contentsOf: URL(fileURLWithPath: pem.path.replacingOccurrences(of: ".pem", with: ".crt")))
        let key = try Data(contentsOf: pem)
        try (key + crt).write(to: pem)
        self.pemPath = pem.path
    }

    private let pemPath: String
    private var stderrURL: URL?

    /// Body bytes the server actually managed to write before the client hung
    /// up. This is what distinguishes "rejected after buffering it all" from
    /// "killed mid-transfer" — the whole point of the rewrite.
    /// Waits briefly for the count to land: when the client aborts mid-transfer
    /// the client's error surfaces immediately, while the server only notices
    /// on its next blocked write — so reading straight away races it.
    func bytesServed() -> Int? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let text = try? String(contentsOf: sentURL, encoding: .utf8),
               let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return n
            }
            usleep(50_000)
        } while Date() < deadline
        return nil
    }
    private var sentURL: URL { dir.appendingPathComponent("sent.txt") }

    /// Everything the server wrote to stderr — printed when it never came up.
    var diagnostics: String {
        guard let stderrURL, let d = try? Data(contentsOf: stderrURL) else { return "(no stderr)" }
        return String(decoding: d, as: UTF8.self)
    }

    func serve(_ data: Data, declaredLength: Bool) {
        try? data.write(to: payloadURL)
        start(declaredLength: declaredLength)
        waitUntilListening()
    }

    private func start(declaredLength: Bool) {
        let script = """
        import http.server, ssl, sys
        payload = open(sys.argv[1], 'rb').read()
        declared = sys.argv[2] == '1'
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Type', 'application/xml')
                if declared:
                    self.send_header('Content-Length', str(len(payload)))
                else:
                    self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                sent = 0
                try:
                    step = 65536
                    if declared:
                        for i in range(0, len(payload), step):
                            chunk = payload[i:i+step]
                            self.wfile.write(chunk); self.wfile.flush()
                            sent += len(chunk)
                    else:
                        for i in range(0, len(payload), step):
                            chunk = payload[i:i+step]
                            self.wfile.write(b'%X\\r\\n' % len(chunk) + chunk + b'\\r\\n')
                            self.wfile.flush()
                            sent += len(chunk)
                        self.wfile.write(b'0\\r\\n\\r\\n')
                except Exception:
                    pass  # client hung up mid-transfer — that is the point
                open(sys.argv[5], 'w').write(str(sent))
            def log_message(self, *a): pass
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(sys.argv[4])
        srv = http.server.HTTPServer(('127.0.0.1', int(sys.argv[3])), H)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        srv.serve_forever()
        """
        let scriptURL = dir.appendingPathComponent("server.py")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) }
        catch { print("SERVER-SCRIPT-WRITE-FAILED \(error)"); return }

        let errURL = dir.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let errHandle = FileHandle(forWritingAtPath: errURL.path) else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.python3!)
        p.arguments = [scriptURL.path, payloadURL.path, declaredLength ? "1" : "0", "\(port)", pemPath, sentURL.path]
        p.standardOutput = errHandle
        p.standardError = errHandle
        do { try p.run() } catch { print("SERVER-SPAWN-FAILED \(error)"); return }
        process = p
        self.stderrURL = errURL
    }

    private func waitUntilListening() {
        for _ in 0..<100 {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(sock) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if ok { return }
            usleep(50_000)
        }
        print("SERVER-NEVER-LISTENED on port \(port):\n\(diagnostics)")
    }

    func stop() {
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: dir)
    }
}
