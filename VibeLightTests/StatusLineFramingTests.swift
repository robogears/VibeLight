import XCTest
@testable import VibeLight

/// Locks in the `@VL` status-protocol framing fix.
///
/// The helper frames one status line per `\n`. VibeLight used to read that with
/// Foundation's `AsyncLineSequence`, which ends a line on the *Unicode* set —
/// LF, CR, NEL (U+0085), LS (U+2028), PS (U+2029). Host-supplied app names flow
/// into those lines, so an app named `Game<U+2028>@VL STARTED` split one status
/// into two on the reader's side, and the second half was parsed as a genuine
/// `@VL STARTED` — the launcher would show a live stream that never began.
///
/// These tests read bytes through the same splitter the session manager uses.
final class StatusLineFramingTests: XCTestCase {

    /// Feeds a byte string through `newlineDelimitedLines` and collects the result.
    private func lines(of text: String) async throws -> [String] {
        var out: [String] = []
        for try await line in AsyncByteFixture(bytes: Array(text.utf8)).newlineDelimitedLines {
            out.append(line)
        }
        return out
    }

    // MARK: The regression

    func testUnicodeSeparatorsDoNotSplitAStatusLine() async throws {
        // Every separator AsyncLineSequence honours but the helper never framed on.
        for separator in ["\u{2028}", "\u{2029}", "\u{0085}", "\u{000B}", "\u{000C}", "\r"] {
            let forged = "@VL LAUNCHING app=\"Game\(separator)@VL STARTED\"\n"
            let got = try await lines(of: forged)
            XCTAssertEqual(got.count, 1,
                           "U+\(String(format: "%04X", separator.unicodeScalars.first!.value)) split one status line into \(got.count)")
            XCTAssertTrue(got[0].hasPrefix("@VL LAUNCHING"),
                          "the surviving line must be the one the helper actually sent")
        }
    }

    func testCRLFStillYieldsACleanLine() async throws {
        // A lone trailing CR is trimmed, so a CRLF writer parses identically —
        // but CR alone (above) must NOT be treated as a terminator.
        let got = try await lines(of: "@VL STARTED\r\n@VL BYE\r\n")
        XCTAssertEqual(got, ["@VL STARTED", "@VL BYE"])
    }

    // MARK: Ordinary framing still works

    func testSplitsOnNewlineAndKeepsOrder() async throws {
        let got = try await lines(of: "@VL LAUNCHING app=\"Steam\"\n@VL STARTED\n@VL BYE\n")
        XCTAssertEqual(got, ["@VL LAUNCHING app=\"Steam\"", "@VL STARTED", "@VL BYE"])
    }

    func testTrailingPartialLineIsDeliveredAtEOF() async throws {
        // The helper is SIGKILLed mid-write: don't lose the last status.
        let got = try await lines(of: "@VL STARTED\n@VL PARTIAL")
        XCTAssertEqual(got, ["@VL STARTED", "@VL PARTIAL"])
    }

    func testEmptyLinesArePreservedNotCoalesced() async throws {
        let got = try await lines(of: "a\n\nb\n")
        XCTAssertEqual(got, ["a", "", "b"])
    }

    func testUTF8MultibyteSurvivesTheSplit() async throws {
        let got = try await lines(of: "@VL LAUNCHING app=\"Café 東京 🎮\"\n")
        XCTAssertEqual(got, ["@VL LAUNCHING app=\"Café 東京 🎮\""])
    }

    // MARK: The unbounded-buffer guard

    func testOverlongLineIsDroppedAndTheStreamResyncs() async throws {
        // A helper that never emits \n must not grow the buffer forever. The
        // runaway line is discarded; the NEXT well-formed line still parses.
        let runaway = String(repeating: "x", count: NewlineDelimitedLines<AsyncByteFixture>.maxLineBytes + 512)
        let got = try await lines(of: runaway + "\n@VL STARTED\n")
        XCTAssertEqual(got, ["@VL STARTED"])
    }

    func testALineExactlyAtTheCapStillParses() async throws {
        let atCap = String(repeating: "x", count: NewlineDelimitedLines<AsyncByteFixture>.maxLineBytes)
        let got = try await lines(of: atCap + "\n")
        XCTAssertEqual(got, [atCap])
    }

    // MARK: FAILED lines reach the user whole (audit ERR-helper-failure-reason-dropped)

    func testStageFailureWithoutReasonBecomesAPlainMessage() {
        // The helper's onStageFailed shape — no reason= at all. This used to be
        // dropped, leaving "The stream exited before it started."
        let got = StreamSessionManager.failureMessage(
            fromStatusBody: #"FAILED code=10060 stage="RTSP handshake" ports="TCP 48010, UDP 47998""#)
        XCTAssertEqual(got, "Couldn't start the stream: RTSP handshake failed (error 10060). "
                       + "Check that the PC's firewall allows ports TCP 48010, UDP 47998, then try again.")
    }

    func testStageFailureWithNoPortsStillSaysWhatToDo() {
        let got = StreamSessionManager.failureMessage(
            fromStatusBody: #"FAILED code=-1 stage="name resolution" ports="""#)
        XCTAssertEqual(got, "Couldn't start the stream: name resolution failed (error -1). "
                       + "Check that the PC is on and reachable, then try again.")
    }

    func testEscapedQuoteInReasonIsNotCutShort() {
        // sanitize() writes \" for a quote and \\ for a backslash.
        let got = StreamSessionManager.failureMessage(
            fromStatusBody: #"FAILED code=2 reason="Couldn't launch \"Halo\" on Bob\\PC.""#)
        XCTAssertEqual(got, #"Couldn't launch "Halo" on Bob\PC."#)
    }

    func testPlainReasonStillWins() {
        let got = StreamSessionManager.failureMessage(
            fromStatusBody: #"FAILED code=0 reason="The PC refused the stream.""#)
        XCTAssertEqual(got, "The PC refused the stream.")
    }

    func testUnterminatedOrEmptyFieldsYieldNothing() {
        XCTAssertNil(StreamSessionManager.failureMessage(fromStatusBody: #"FAILED code=3 reason="cut off"#))
        XCTAssertNil(StreamSessionManager.failureMessage(fromStatusBody: #"FAILED code=3 reason="""#))
        XCTAssertNil(StreamSessionManager.failureMessage(fromStatusBody: "FAILED code=3"))
    }
}

/// A minimal `AsyncSequence` of bytes, standing in for `FileHandle.AsyncBytes`.
struct AsyncByteFixture: AsyncSequence {
    typealias Element = UInt8
    let bytes: [UInt8]

    struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: [UInt8]
        var index = 0
        mutating func next() async -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(bytes: bytes) }
}
