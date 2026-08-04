import XCTest
@testable import VibeLight

/// Proof that `CappedResponseReader` bounds memory **while bytes arrive**,
/// driven against a real local HTTP server rather than a URLProtocol stub (a
/// stub would bypass the very delegate callbacks under test).
///
/// This is the shared reader behind `HostPairing` (plaintext HTTP :47989, the
/// one leg anyone on the path can answer) and `MoonDeckBuddyClient`. Both used
/// to check `data.count` AFTER `URLSession.data(for:)` had already buffered the
/// whole body — which bounds nothing, and could not fire at all on a chunked
/// reply, since that declares no length to check. `testChunkedOversizeIsAborted`
/// is the test that distinguishes the two implementations: it asserts on what
/// the SERVER managed to send, because the old code produced the same error
/// message only after consuming every byte.
final class CappedResponseReaderTests: XCTestCase {

    private var server: LocalTLSServer!
    private let cap = 256 * 1024

    override func setUpWithError() throws {
        try XCTSkipIf(LocalTLSServer.python3 == nil, "python3 unavailable")
        server = try LocalTLSServer()
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    /// A reader plus a session wired to it — the arrangement both real callers
    /// build. Plaintext, matching the pairing client's leg.
    private func makeReader() -> (CappedResponseReader, URLSession, URLRequest) {
        let reader = CappedResponseReader()
        let session = URLSession(configuration: .ephemeral, delegate: reader, delegateQueue: nil)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/pair")!)
        req.setValue("close", forHTTPHeaderField: "Connection")
        return (reader, session, req)
    }

    // MARK: - The path must still work

    func testNormalResponseIsReturnedIntact() async throws {
        let body = #"<root status_code="200"><plaincert>DEADBEEF</plaincert></root>"#
        server.serve(Data(body.utf8), declaredLength: true, tls: false)

        let (reader, session, req) = makeReader()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await reader.read(session, req, cap: cap)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), body)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// Chunked bodies carry no declared length, so they exercise the per-chunk
    /// accumulation path rather than the header check.
    func testChunkedResponseUnderCapIsReturnedIntact() async throws {
        let body = String(repeating: "A", count: 100 * 1024)   // under the 256 KB cap
        server.serve(Data(body.utf8), declaredLength: false, tls: false)

        let (reader, session, req) = makeReader()
        defer { session.finishTasksAndInvalidate() }
        let (data, _) = try await reader.read(session, req, cap: cap)

        XCTAssertEqual(data.count, 100 * 1024, "a legal chunked body must survive intact")
    }

    // MARK: - The cap

    func testDeclaredOversizeIsRefusedBeforeTheBodyIsRead() async throws {
        server.serve(Data(repeating: 0x41, count: 20 * 1024 * 1024), declaredLength: true, tls: false)

        let (reader, session, req) = makeReader()
        defer { session.finishTasksAndInvalidate() }
        do {
            _ = try await reader.read(session, req, cap: cap)
            XCTFail("a 20 MB declared body must be refused")
        } catch let error as CappedResponseReader.TooLarge {
            XCTAssertGreaterThan(error.bytes, cap)
        }

        // The property that matters: the 20 MB body is not consumed. It is not
        // zero — the server writes into the socket buffer before the client's
        // refusal reaches it, ~1 MB on loopback — but it is nowhere near the
        // whole payload, which is exactly what the old post-hoc check DID read.
        let served = server.bytesServed() ?? 0
        XCTAssertLessThan(served, 4 * 1024 * 1024,
                          "declared oversize must be refused up front; server sent \(served)")
    }

    func testChunkedOversizeIsAbortedMidTransfer() async throws {
        // No declared length — exactly the shape the old post-hoc check could
        // never catch, because there was nothing to check until it was all in.
        server.serve(Data(repeating: 0x42, count: 20 * 1024 * 1024), declaredLength: false, tls: false)

        let (reader, session, req) = makeReader()
        defer { session.finishTasksAndInvalidate() }
        do {
            _ = try await reader.read(session, req, cap: cap)
            XCTFail("an undeclared 20 MB body must be refused")
        } catch {
            // Either the cap error or the cancellation it triggers is fine —
            // the server-side byte count below is the real assertion.
        }

        let served = server.bytesServed() ?? Int.max
        XCTAssertLessThan(served, 20 * 1024 * 1024,
                          "transfer must be aborted before the full body is served; server sent \(served)")
    }

    /// Cancelling the awaiting Task must tear the transfer down, not just stop
    /// awaiting it — otherwise the download keeps running and keeps filling a
    /// buffer nobody will read.
    func testTaskCancellationAbortsTheTransfer() async throws {
        // Throttled to a drip (10 ms per 64 KB chunk ≈ 3 s for the payload) so
        // the cancel lands mid-transfer instead of after loopback has already
        // delivered everything.
        server.serve(Data(repeating: 0x43, count: 20 * 1024 * 1024),
                     declaredLength: false, tls: false, chunkDelay: 0.01)

        let (reader, session, req) = makeReader()
        defer { session.finishTasksAndInvalidate() }
        // Cap set far above the payload so ONLY cancellation can stop this.
        let task = Task { try await reader.read(session, req, cap: 64 * 1024 * 1024) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled read must not return a body")
        } catch {
            // Expected: cancelled.
        }
        let served = server.bytesServed() ?? Int.max
        XCTAssertLessThan(served, 20 * 1024 * 1024,
                          "cancellation must stop the transfer; server sent \(served)")
    }
}
