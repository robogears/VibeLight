import Foundation

/// A paired streaming host imported from Moonlight (or added natively later).
struct StreamHost: Identifiable, Hashable, Sendable {
    let id: String            // host UUID from pairing
    var name: String
    var localAddress: String?
    var localPort: Int
    var remoteAddress: String?
    var remotePort: Int
    var manualAddress: String?
    var manualPort: Int
    var macAddress: Data?     // for wake-on-LAN
    var serverCertPEM: Data?  // pinned server cert from pairing (empty = unpaired)
    var apps: [StreamApp]

    /// A host is only usable if pairing completed (server cert pinned).
    var isPaired: Bool { serverCertPEM?.isEmpty == false }

    /// Candidate addresses in connection-preference order.
    var candidateAddresses: [(host: String, port: Int)] {
        var seen = Set<String>()
        var out: [(String, Int)] = []
        for (addr, port) in [
            (manualAddress, manualPort),
            (localAddress, localPort),
            (remoteAddress, remotePort),
        ] {
            guard let addr, !addr.isEmpty, !seen.contains(addr) else { continue }
            seen.insert(addr)
            out.append((addr, port == 0 ? 47989 : port))
        }
        return out
    }
}

/// An app/game exposed by the host.
struct StreamApp: Identifiable, Hashable, Sendable {
    let id: Int               // host-side app ID (CRC32 of UUID on Vibepollo; unstable on stock Sunshine)
    let rawName: String       // may contain zero-width ordering hacks from Apollo-family hosts
    var uuid: String?         // Vibepollo/Apollo stable identity — preferred cache/identity key
    var idx: Int?             // host-defined sort order (Vibepollo/Apollo)
    var isHDRSupported: Bool
    var isHidden: Bool

    /// Display name with Apollo/MoonDeck zero-width ordering prefixes stripped.
    var name: String {
        rawName.strippingZeroWidthCharacters()
    }
}

/// The client-side pairing identity Moonlight established with hosts.
/// Reused by VibeLight for mTLS against the host API — no re-pairing needed.
struct ClientIdentity: Sendable {
    let certificatePEM: Data
    let privateKeyPEM: Data
    /// Moonlight derives its uniqueid as "0123456789ABCDEF" (fixed) in modern versions.
    let uniqueID: String
}

/// Stream quality defaults imported from the user's Moonlight settings.
struct StreamSettings: Sendable, Codable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var hdr: Bool
    var vsync: Bool
    var framePacing: Bool

    static let fallback = StreamSettings(
        width: 1920, height: 1080, fps: 60, bitrateKbps: 20000,
        hdr: false, vsync: true, framePacing: false
    )
}

extension String {
    /// Apollo-family hosts and MoonDeck prefix app names with U+200B/U+200C/U+200D
    /// to force sort order in Moonlight. Strip them for display and artwork matching.
    /// Filters at the unicode-scalar level: consecutive zero-width scalars merge
    /// into grapheme clusters, so Character-level filtering misses them.
    func strippingZeroWidthCharacters() -> String {
        let zeroWidth: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]
        return String(String.UnicodeScalarView(unicodeScalars.filter { !zeroWidth.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
    }
}
