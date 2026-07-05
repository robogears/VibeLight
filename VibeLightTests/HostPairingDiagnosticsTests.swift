import XCTest
@testable import VibeLight

/// Live pairing failed opaquely because host-side error details were dropped and
/// a CRLF-lined cert silently produced empty DER. These lock the diagnostics +
/// the parsing fix so a real host failure is legible, not a generic stage error.
final class HostPairingDiagnosticsTests: XCTestCase {

    // MARK: - Host status_code / status_message surfacing

    func testStageMessageFoldsInHostStatus() {
        let xml = #"<?xml version="1.0"?><root status_code="400" status_message="Out of order call to getservercert" paired="0"></root>"#
        let msg = HostPairing.stageMessage(xml: xml, fallback: "Pairing failed (stage 1).")
        XCTAssertEqual(msg, "Pairing failed (stage 1). Host says: Out of order call to getservercert (400).")
    }

    func testStageMessageMessageOnly() {
        let xml = #"<root status_message="PIN expired" paired="0"/>"#
        XCTAssertEqual(HostPairing.stageMessage(xml: xml, fallback: "Failed."),
                       "Failed. Host says: PIN expired.")
    }

    func testStageMessageCodeOnly() {
        let xml = #"<root status_code="503" paired="0"/>"#
        XCTAssertEqual(HostPairing.stageMessage(xml: xml, fallback: "Failed."),
                       "Failed. Host status 503.")
    }

    func testStageMessageFallsBackWhenNoStatus() {
        // A bare paired=0 with no status attributes → just the fallback.
        XCTAssertEqual(HostPairing.stageMessage(xml: "<root paired=\"0\"/>", fallback: "Failed."), "Failed.")
        // status_code=200 with no message is not an error detail → fallback only.
        XCTAssertEqual(HostPairing.stageMessage(xml: "<root status_code=\"200\"/>", fallback: "Failed."), "Failed.")
    }

    func testAttributeValueExtraction() {
        let xml = #"<root a="one" b="" c="three">"#
        XCTAssertEqual(HostPairing.attributeValue(xml, "a"), "one")
        XCTAssertNil(HostPairing.attributeValue(xml, "b"), "empty attribute → nil")
        XCTAssertEqual(HostPairing.attributeValue(xml, "c"), "three")
        XCTAssertNil(HostPairing.attributeValue(xml, "missing"))
    }

    // MARK: - CRLF PEM regression (silently produced empty DER before)

    func testPemToDERToleratesCRLF() {
        let lf = GameStreamCryptoTests.sampleCertPEM
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let derLF = GameStreamCrypto.pemToDER(Data(lf.utf8))
        let derCRLF = GameStreamCrypto.pemToDER(Data(crlf.utf8))
        XCTAssertNotNil(derCRLF)
        XCTAssertFalse(derCRLF?.isEmpty ?? true, "CRLF PEM must not decode to empty DER")
        XCTAssertEqual(derCRLF, derLF, "CRLF and LF PEMs must yield identical DER")
    }
}
