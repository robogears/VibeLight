import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The exact crypto primitives the GameStream pairing handshake needs, ported
/// from moonlight-qt's NvPairingManager (AES-128-ECB **without padding**,
/// SHA-256, RSA-SHA256 sign/verify, and X.509 signature extraction).
enum GameStreamCrypto {

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        // This RNG feeds security-critical material (pairing salt, client
        // challenge/secret, PIN, iOS cert serial). A random-source failure is
        // unrecoverable — fail loudly rather than silently return zeros, which
        // would hand out predictable "random" bytes.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return data
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: - AES-128-ECB (no padding, block-aligned inputs)

    static func aesEcbEncrypt(_ plaintext: Data, key: Data) -> Data? {
        aesEcb(CCOperation(kCCEncrypt), plaintext, key: key)
    }

    static func aesEcbDecrypt(_ ciphertext: Data, key: Data) -> Data? {
        aesEcb(CCOperation(kCCDecrypt), ciphertext, key: key)
    }

    private static func aesEcb(_ op: CCOperation, _ input: Data, key: Data) -> Data? {
        guard !input.isEmpty, key.count == kCCKeySizeAES128 else { return input.isEmpty ? Data() : nil }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, key.count,
                            nil,
                            inPtr.baseAddress, input.count,
                            outPtr.baseAddress, outCapacity, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
    }

    // MARK: - RSA-SHA256

    /// Signs a message with the client's private key (RSA PKCS#1 v1.5 + SHA-256).
    static func sign(_ message: Data, privateKey: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        let sig = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                        message as CFData, &error)
        return sig as Data?
    }

    /// Verifies a signature against the server certificate's public key.
    static func verify(_ message: Data, signature: Data, serverCertPEM: Data) -> Bool {
        guard let der = pemToDER(serverCertPEM),
              let cert = SecCertificateCreateWithData(nil, der as CFData),
              let pubKey = SecCertificateCopyKey(cert) else { return false }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(pubKey, .rsaSignatureMessagePKCS1v15SHA256,
                                     message as CFData, signature as CFData, &error)
    }

    // MARK: - X.509 signature bytes

    /// The raw signature bytes of a self-signed cert — the third element of the
    /// Certificate SEQUENCE (a BIT STRING), minus its leading unused-bits byte.
    /// moonlight mixes these into the pairing challenge hash.
    static func x509SignatureBytes(pem: Data) -> Data? {
        guard let der = pemToDER(pem) else { return nil }
        let bytes = [UInt8](der)
        var pos = 0

        func readTLV() -> (tag: UInt8, range: Range<Int>)? {
            guard pos < bytes.count else { return nil }
            let tag = bytes[pos]; pos += 1
            guard pos < bytes.count else { return nil }
            var len = Int(bytes[pos]); pos += 1
            if len & 0x80 != 0 {
                let n = len & 0x7f
                guard n >= 1, n <= 4, pos + n <= bytes.count else { return nil }
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(bytes[pos]); pos += 1 }
            }
            guard pos + len <= bytes.count else { return nil }
            let range = pos..<(pos + len)
            pos += len
            return (tag, range)
        }

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        guard let (outerTag, outer) = readTLV(), outerTag == 0x30 else { return nil }
        pos = outer.lowerBound
        guard readTLV() != nil else { return nil }              // tbsCertificate
        guard readTLV() != nil else { return nil }              // signatureAlgorithm
        guard let (sigTag, sig) = readTLV(), sigTag == 0x03,    // signatureValue BIT STRING
              sig.count >= 2 else { return nil }
        // First content byte is the count of unused bits (always 0 here).
        return Data(bytes[(sig.lowerBound + 1)..<sig.upperBound])
    }

    // MARK: - PEM

    static func pemToDER(_ pem: Data) -> Data? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        let body = text
            .replacingOccurrences(of: "\r", with: "")   // tolerate CRLF PEMs
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: body)
    }
}

extension Data {
    /// Lowercase hex, as GameStream expects on the wire.
    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            out.append(byte)
            i += 2
        }
        self = out
    }
}
