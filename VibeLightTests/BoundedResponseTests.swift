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
    private var identityDir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(LocalTLSServer.python3 == nil, "python3 unavailable")
        server = try LocalTLSServer()
        identityDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vl-bounded-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        server?.stop()
        server = nil
        if let identityDir { try? FileManager.default.removeItem(at: identityDir) }
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

    private func client() throws -> HostAPIClient {
        try TestHostAPIClient.make(in: identityDir)
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

        let api = try client()
        do {
            _ = try await api.serverInfo(for: host())
            XCTFail("a 20 MB response must be rejected")
        } catch {
            XCTAssertTrue("\(error)".contains("too large"), "unexpected error: \(error)")
        }
        // The property that matters, and the one the OLD code failed: a declared
        // oversize is refused from the headers, so the body is never read.
        // Asserting only the error message would pass against the previous
        // implementation, which buffered all 20 MB and complained afterwards.
        //
        // Not zero: the server writes into the loopback socket buffers before
        // the refusal reaches it (measured ~0.4 MB here). The ceiling is those
        // two buffers' macOS maximum (4 MB each way), so machine load can't
        // push past it — and it is still half the 16 MB cap, so a client that
        // read the body and refused only on reaching the cap fails it. The old
        // 1 MB ceiling sat inside the buffering margin.
        // (audit QUA-bounded-test-loopback-flake)
        let served = try XCTUnwrap(server.bytesServed(), "the server never reported what it sent")
        XCTAssertLessThan(served, 8 * 1024 * 1024,
                          "declared oversize must be refused before the body is read; server sent \(served) bytes")
    }

    func testOversizedBodyWithNoContentLengthIsRejectedMidTransfer() async throws {
        // Chunked, no declared length — the case the old post-hoc check could
        // not catch, because the body was fully buffered before it ran.
        // 64 MB, not 20: the abort lands just past the 16 MB cap (measured
        // 16 MB + one 64 KB chunk), and a 20 MB payload left under 4 MB of room
        // for loopback buffering and a slow delegate queue on a loaded machine.
        // (audit QUA-bounded-test-loopback-flake)
        let payload = 64 * 1024 * 1024
        server.serve(Data(repeating: 0x42, count: payload), declaredLength: false)

        let api = try client()
        do {
            _ = try await api.serverInfo(for: host())
            XCTFail("an undeclared 64 MB response must be rejected")
        } catch {
            XCTAssertTrue("\(error)".contains("too large"), "unexpected error: \(error)")
        }
        // Killed MID-transfer: the server must not have managed to send the
        // whole body. The old post-hoc check consumed every byte first, so this
        // assertion — not the error message — is what proves the fix.
        let served = try XCTUnwrap(server.bytesServed(), "the server never reported what it sent")
        XCTAssertLessThan(served, payload,
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

// MARK: - A client that never touches the real app's data

/// A `HostAPIClient` whose client identity, PKCS#12 cache and `uniqueid` all
/// live in `directory`. The Mac tests run inside a copy of the app with the
/// real app's bundle id, so the defaults (`IdentityStore.resolve`, the
/// provider's Application Support folder, `IdentityStore.uniqueID()`) are the
/// owner's REAL identity, cached bundle and preferences — the provider even
/// prunes "stale" bundles in its folder. (audit QUA-macos-tests-boot-real-app)
enum TestHostAPIClient {
    static func make(in directory: URL) throws -> HostAPIClient {
        guard case .ready(let cert, let key) = IdentityStore.loadOrCreateOwn(
            in: directory.appendingPathComponent("identity", isDirectory: true)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "could not create a throwaway client identity in \(directory.path)"])
        }
        let identity = ClientIdentity(certificatePEM: cert, privateKeyPEM: key, uniqueID: "0123456789abcdef")
        let provider = ClientIdentityProvider(
            identity: identity, supportDirectory: directory, identityProblem: nil)
        return HostAPIClient(identityProvider: provider, uniqueID: identity.uniqueID)
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

    /// The port the server actually bound — valid once `serve` returns. The OS
    /// picks it (bind to port 0), so two servers can never collide, whether in
    /// this run or in another checkout's tests running at the same time.
    private(set) var port = 0
    private var process: Process?
    private let dir: URL
    private let payloadURL: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibelight-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        payloadURL = dir.appendingPathComponent("payload.bin")

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
        // Generous: under heavy machine load Python can take seconds to notice
        // the hang-up. Only a missing count waits; a present one returns at once.
        let deadline = Date().addingTimeInterval(30)
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

    /// `chunkDelay` throttles the server to a slow drip so a test can cancel
    /// mid-transfer deterministically — over loopback an unthrottled 20 MB
    /// arrives faster than any sleep a test could wait.
    func serve(_ data: Data, declaredLength: Bool, tls: Bool = true, chunkDelay: Double = 0) {
        try? data.write(to: payloadURL)
        start(declaredLength: declaredLength, tls: tls, chunkDelay: chunkDelay)
        waitUntilReady()
    }

    private func start(declaredLength: Bool, tls: Bool = true, chunkDelay: Double = 0) {
        let script = """
        import http.server, os, ssl, sys, time
        def publish(path, text):
            # Write-then-rename, so the test never reads a half-written number.
            open(path + '.tmp', 'w').write(text)
            os.replace(path + '.tmp', path)
        payload = open(sys.argv[1], 'rb').read()
        declared = sys.argv[2] == '1'
        delay = float(sys.argv[7])
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
                            if delay: time.sleep(delay)
                    else:
                        for i in range(0, len(payload), step):
                            chunk = payload[i:i+step]
                            self.wfile.write(b'%X\\r\\n' % len(chunk) + chunk + b'\\r\\n')
                            self.wfile.flush()
                            sent += len(chunk)
                            if delay: time.sleep(delay)
                        self.wfile.write(b'0\\r\\n\\r\\n')
                except Exception:
                    pass  # client hung up mid-transfer — that is the point
                publish(sys.argv[5], str(sent))
            def log_message(self, *a): pass
        srv = http.server.HTTPServer(('127.0.0.1', 0), H)
        if sys.argv[6] == '1':
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(sys.argv[4])
            srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        # Announced only now: listening AND wrapped, so the first connection the
        # test makes is the real request, never a race with start-up.
        publish(sys.argv[3], str(srv.server_address[1]))
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
        p.arguments = [scriptURL.path, payloadURL.path, declaredLength ? "1" : "0", portURL.path,
                       pemPath, sentURL.path, tls ? "1" : "0", "\(chunkDelay)"]
        p.standardOutput = errHandle
        p.standardError = errHandle
        do { try p.run() } catch { print("SERVER-SPAWN-FAILED \(error)"); return }
        process = p
        self.stderrURL = errURL
    }

    private var portURL: URL { dir.appendingPathComponent("port.txt") }

    /// Waits for the server to announce the port it bound. This used to probe a
    /// random fixed port for at most 5 s and then carry on regardless; on a
    /// heavily loaded Mac Python could take longer than that to start (or the
    /// random port was already taken), and the test then failed as
    /// `unreachable("Local Test Host")` — a test-harness race, not a bug in the
    /// code under test. (audit QUA-bounded-test-loopback-flake)
    private func waitUntilReady() {
        let deadline = Date().addingTimeInterval(60)
        repeat {
            if let text = try? String(contentsOf: portURL, encoding: .utf8),
               let bound = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), bound > 0 {
                port = bound
                return
            }
            // A server that died (bad script, missing cert) will never announce.
            if let process, !process.isRunning { break }
            usleep(20_000)
        } while Date() < deadline
        print("SERVER-NEVER-LISTENED:\n\(diagnostics)")
    }

    func stop() {
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: dir)
    }
}
