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

/// When Moonlight grabs system keyboard shortcuts (Cmd-Tab etc.), mapped to
/// `--capture-system-keys`.
enum CaptureSystemKeys: String, Codable, CaseIterable, Sendable {
    case never, fullscreen, always
    var label: String {
        switch self {
        case .never: "Never"; case .fullscreen: "In Fullscreen"; case .always: "Always"
        }
    }
    var cliValue: String { rawValue }
}

/// Full streaming configuration — mirrors the meaningful Moonlight settings so
/// the couch UI has the same control the desktop app does. Imported defaults
/// come from the user's Moonlight prefs; everything is persisted by VibeLight.
///
/// Codable is DECODE-lenient (custom `init(from:)` with `decodeIfPresent`) so
/// adding a field never invalidates a user's saved settings — missing keys just
/// take the fallback default.
struct StreamSettings: Sendable, Codable, Equatable {
    // Video
    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var codec: VideoCodec
    var hdr: Bool
    var decoder: VideoDecoder
    var yuv444: Bool
    // Audio
    var audio: AudioConfig
    var muteHostSpeakers: Bool     // → --no-audio-on-host
    var muteOnFocusLoss: Bool
    // Input
    var absoluteMouse: Bool        // "optimize mouse for remote desktop"
    var swapMouseButtons: Bool
    var reverseScrolling: Bool
    var captureSystemKeys: CaptureSystemKeys
    var swapGamepadButtons: Bool
    var backgroundGamepad: Bool
    var touchControls: Bool        // iOS: direct touch drives the remote screen
    // Advanced
    var vsync: Bool
    var framePacing: Bool
    var gameOptimizations: Bool
    var quitAppAfter: Bool         // quit the app on the host after the stream ends
    var keepAwake: Bool
    var performanceOverlay: Bool
    var stopStreamOnExit: Bool     // /cancel the running game on the host when VibeLight quits

    static let fallback = StreamSettings()

    init(width: Int = 1920, height: Int = 1080, fps: Int = 60, bitrateKbps: Int = 20000,
         codec: VideoCodec = .auto, hdr: Bool = false, decoder: VideoDecoder = .auto,
         yuv444: Bool = false, audio: AudioConfig = .stereo, muteHostSpeakers: Bool = true,
         muteOnFocusLoss: Bool = false, absoluteMouse: Bool = false, swapMouseButtons: Bool = false,
         reverseScrolling: Bool = false, captureSystemKeys: CaptureSystemKeys = .fullscreen,
         swapGamepadButtons: Bool = false, backgroundGamepad: Bool = false, touchControls: Bool = true,
         vsync: Bool = true,
         framePacing: Bool = false, gameOptimizations: Bool = true, quitAppAfter: Bool = false,
         keepAwake: Bool = true, performanceOverlay: Bool = false, stopStreamOnExit: Bool = true) {
        self.width = width; self.height = height; self.fps = fps; self.bitrateKbps = bitrateKbps
        self.codec = codec; self.hdr = hdr; self.decoder = decoder; self.yuv444 = yuv444
        self.audio = audio; self.muteHostSpeakers = muteHostSpeakers; self.muteOnFocusLoss = muteOnFocusLoss
        self.absoluteMouse = absoluteMouse; self.swapMouseButtons = swapMouseButtons
        self.reverseScrolling = reverseScrolling; self.captureSystemKeys = captureSystemKeys
        self.swapGamepadButtons = swapGamepadButtons; self.backgroundGamepad = backgroundGamepad
        self.touchControls = touchControls
        self.vsync = vsync; self.framePacing = framePacing; self.gameOptimizations = gameOptimizations
        self.quitAppAfter = quitAppAfter; self.keepAwake = keepAwake; self.performanceOverlay = performanceOverlay
        self.stopStreamOnExit = stopStreamOnExit
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let f = StreamSettings.fallback
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? f.width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? f.height
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? f.fps
        bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps) ?? f.bitrateKbps
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? f.codec
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? f.hdr
        self.decoder = try c.decodeIfPresent(VideoDecoder.self, forKey: .decoder) ?? f.decoder
        yuv444 = try c.decodeIfPresent(Bool.self, forKey: .yuv444) ?? f.yuv444
        audio = try c.decodeIfPresent(AudioConfig.self, forKey: .audio) ?? f.audio
        muteHostSpeakers = try c.decodeIfPresent(Bool.self, forKey: .muteHostSpeakers) ?? f.muteHostSpeakers
        muteOnFocusLoss = try c.decodeIfPresent(Bool.self, forKey: .muteOnFocusLoss) ?? f.muteOnFocusLoss
        absoluteMouse = try c.decodeIfPresent(Bool.self, forKey: .absoluteMouse) ?? f.absoluteMouse
        swapMouseButtons = try c.decodeIfPresent(Bool.self, forKey: .swapMouseButtons) ?? f.swapMouseButtons
        reverseScrolling = try c.decodeIfPresent(Bool.self, forKey: .reverseScrolling) ?? f.reverseScrolling
        captureSystemKeys = try c.decodeIfPresent(CaptureSystemKeys.self, forKey: .captureSystemKeys) ?? f.captureSystemKeys
        swapGamepadButtons = try c.decodeIfPresent(Bool.self, forKey: .swapGamepadButtons) ?? f.swapGamepadButtons
        backgroundGamepad = try c.decodeIfPresent(Bool.self, forKey: .backgroundGamepad) ?? f.backgroundGamepad
        touchControls = try c.decodeIfPresent(Bool.self, forKey: .touchControls) ?? f.touchControls
        vsync = try c.decodeIfPresent(Bool.self, forKey: .vsync) ?? f.vsync
        framePacing = try c.decodeIfPresent(Bool.self, forKey: .framePacing) ?? f.framePacing
        gameOptimizations = try c.decodeIfPresent(Bool.self, forKey: .gameOptimizations) ?? f.gameOptimizations
        quitAppAfter = try c.decodeIfPresent(Bool.self, forKey: .quitAppAfter) ?? f.quitAppAfter
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? f.keepAwake
        performanceOverlay = try c.decodeIfPresent(Bool.self, forKey: .performanceOverlay) ?? f.performanceOverlay
        stopStreamOnExit = try c.decodeIfPresent(Bool.self, forKey: .stopStreamOnExit) ?? f.stopStreamOnExit
    }
}

/// A named, user-saved snapshot of stream settings — selectable from the home
/// screen so the user can flip between e.g. "4K 60" and "1080p 120" per session.
struct StreamPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var settings: StreamSettings

    /// A short "1080p · 120 fps" summary for the home-screen rail.
    var summary: String {
        let res: String
        switch (settings.width, settings.height) {
        case (1280, 720): res = "720p"
        case (1920, 1080): res = "1080p"
        case (2560, 1440), (3440, 1440): res = "1440p"
        case (3840, 2160): res = "4K"
        default: res = "\(settings.height)p"
        }
        return "\(res) · \(settings.fps) fps"
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
