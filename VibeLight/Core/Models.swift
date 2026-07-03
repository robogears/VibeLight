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

/// Video codec, mapped to the Moonlight CLI's `--video-codec` values.
enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case auto, h264, hevc, av1
    var label: String {
        switch self {
        case .auto: "Auto"; case .h264: "H.264"; case .hevc: "HEVC (H.265)"; case .av1: "AV1"
        }
    }
    var cliValue: String {
        switch self {
        case .auto: "auto"; case .h264: "H.264"; case .hevc: "HEVC"; case .av1: "AV1"
        }
    }
}

/// Audio channel layout, mapped to `--audio-config`.
enum AudioConfig: String, Codable, CaseIterable, Sendable {
    case stereo, surround51, surround71
    var label: String {
        switch self {
        case .stereo: "Stereo"; case .surround51: "5.1 Surround"; case .surround71: "7.1 Surround"
        }
    }
    var cliValue: String {
        switch self {
        case .stereo: "stereo"; case .surround51: "5.1-surround"; case .surround71: "7.1-surround"
        }
    }
}

/// Decoder preference, mapped to `--video-decoder`.
enum VideoDecoder: String, Codable, CaseIterable, Sendable {
    case auto, hardware, software
    var label: String {
        switch self {
        case .auto: "Auto"; case .hardware: "Hardware"; case .software: "Software"
        }
    }
    var cliValue: String { rawValue }
}

/// Full streaming configuration — mirrors the meaningful Moonlight settings so
/// the couch UI has the same control the desktop app does. Imported defaults
/// come from the user's Moonlight prefs; everything is persisted by VibeLight.
struct StreamSettings: Sendable, Codable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var hdr: Bool
    var vsync: Bool
    var framePacing: Bool
    var codec: VideoCodec
    var audio: AudioConfig
    var decoder: VideoDecoder
    var gameOptimizations: Bool

    static let fallback = StreamSettings(
        width: 1920, height: 1080, fps: 60, bitrateKbps: 20000,
        hdr: false, vsync: true, framePacing: false,
        codec: .auto, audio: .stereo, decoder: .auto, gameOptimizations: true
    )

    // Decode leniently so older persisted settings (before these fields
    // existed) still load — missing keys fall back to sensible defaults.
    init(width: Int, height: Int, fps: Int, bitrateKbps: Int, hdr: Bool,
         vsync: Bool, framePacing: Bool, codec: VideoCodec, audio: AudioConfig,
         decoder: VideoDecoder, gameOptimizations: Bool) {
        self.width = width; self.height = height; self.fps = fps
        self.bitrateKbps = bitrateKbps; self.hdr = hdr; self.vsync = vsync
        self.framePacing = framePacing; self.codec = codec; self.audio = audio
        self.decoder = decoder; self.gameOptimizations = gameOptimizations
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let f = StreamSettings.fallback
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? f.width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? f.height
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? f.fps
        bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps) ?? f.bitrateKbps
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? f.hdr
        vsync = try c.decodeIfPresent(Bool.self, forKey: .vsync) ?? f.vsync
        framePacing = try c.decodeIfPresent(Bool.self, forKey: .framePacing) ?? f.framePacing
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? f.codec
        audio = try c.decodeIfPresent(AudioConfig.self, forKey: .audio) ?? f.audio
        self.decoder = try c.decodeIfPresent(VideoDecoder.self, forKey: .decoder) ?? f.decoder
        gameOptimizations = try c.decodeIfPresent(Bool.self, forKey: .gameOptimizations) ?? f.gameOptimizations
    }
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
