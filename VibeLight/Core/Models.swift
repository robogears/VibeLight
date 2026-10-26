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
/// Codable so the last successful app list can be cached per host — the shelf
/// then survives the PC sleeping instead of going blank. `rawName` round-trips
/// VERBATIM, zero-width padding included: it is what the launch path must hand
/// back to the host, and stripping it here would break launching by name.
struct StreamApp: Identifiable, Hashable, Sendable, Codable {
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
/// The launcher's background style (Settings ▸ Themes). A GLOBAL app appearance
/// preference — deliberately NOT part of `StreamSettings`, so it's never captured
/// into a per-session stream preset.
enum BackgroundTheme: String, Codable, CaseIterable, Sendable {
    // Order here IS the picker/cycle order — STATIC themes first, then ANIMATED
    // ones (see `isAnimated`). Raw values are frozen (they persist in
    // UserDefaults) — never rename an existing case; reordering cases is fine.
    case nightfallSheen, inkPool,                                      // static
         livingGlass, parallaxDeep, constellation, ambient, diagonal,  // animated
         gaslight, searchlightCity, swingingBulb                       // animated — the noir set

    var title: String {
        switch self {
        case .nightfallSheen:  "Nightfall Sheen"
        case .inkPool:         "Ink Pool"
        case .livingGlass:     "Living Glass"
        case .parallaxDeep:    "Parallax Deep"
        case .constellation:   "Constellation"
        case .ambient:         "Ambient"
        case .diagonal:        "Diagonal Drift"
        case .gaslight:        "Gaslight"
        case .searchlightCity: "Searchlight City"
        case .swingingBulb:    "Swinging Bulb"
        }
    }

    /// Whether the theme moves — drives the "Static"/"Animated" tag on each
    /// preview card and the static-first ordering above.
    var isAnimated: Bool {
        switch self {
        case .nightfallSheen, .inkPool: false
        default:                        true
        }
    }
}

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
    var touchWithController: Bool  // iOS: keep touch live while a gamepad is connected
    var externalDisplay: Bool      // iOS: stream to a connected TV at its native res
    // Advanced
    var vsync: Bool
    var framePacing: Bool
    var gameOptimizations: Bool
    var quitAppAfter: Bool         // quit the app on the host after the stream ends
    var keepAwake: Bool
    var performanceOverlay: Bool
    var stopStreamOnExit: Bool     // /cancel the running game on the host when VibeLight quits

    static let fallback = StreamSettings()

    /// The ranges the app itself can produce: the custom-resolution entry, the
    /// Frame Rate presets and the Bitrate row. Saved values are clamped into
    /// them on decode, because nothing else checks a saved number before it
    /// is multiplied or stepped — an Int.max width crashed the resolution
    /// list's sort, and an Int.max bitrate from a preset crashed the Bitrate
    /// arrows. (audit DAT-stored-size-overflow)
    static let widthRange = 256...7680
    static let heightRange = 144...4320
    static let fpsRange = 1...240
    static let bitrateRange = 10_000...200_000

    /// This value with every number pulled into its legal range.
    func clampedToLegalRanges() -> StreamSettings {
        var s = self
        s.width = s.width.clamped(to: Self.widthRange)
        s.height = s.height.clamped(to: Self.heightRange)
        s.fps = s.fps.clamped(to: Self.fpsRange)
        s.bitrateKbps = s.bitrateKbps.clamped(to: Self.bitrateRange)
        return s
    }

    init(width: Int = 1920, height: Int = 1080, fps: Int = 60, bitrateKbps: Int = 20000,
         codec: VideoCodec = .auto, hdr: Bool = false, decoder: VideoDecoder = .auto,
         yuv444: Bool = false, audio: AudioConfig = .stereo, muteHostSpeakers: Bool = true,
         muteOnFocusLoss: Bool = false, absoluteMouse: Bool = false, swapMouseButtons: Bool = false,
         reverseScrolling: Bool = false, captureSystemKeys: CaptureSystemKeys = .fullscreen,
         swapGamepadButtons: Bool = false, backgroundGamepad: Bool = false, touchControls: Bool = true,
         touchWithController: Bool = false,
         externalDisplay: Bool = true,
         vsync: Bool = true,
         framePacing: Bool = false, gameOptimizations: Bool = true, quitAppAfter: Bool = false,
         keepAwake: Bool = true, performanceOverlay: Bool = false, stopStreamOnExit: Bool = true) {
        self.width = width; self.height = height; self.fps = fps; self.bitrateKbps = bitrateKbps
        self.codec = codec; self.hdr = hdr; self.decoder = decoder; self.yuv444 = yuv444
        self.audio = audio; self.muteHostSpeakers = muteHostSpeakers; self.muteOnFocusLoss = muteOnFocusLoss
        self.absoluteMouse = absoluteMouse; self.swapMouseButtons = swapMouseButtons
        self.reverseScrolling = reverseScrolling; self.captureSystemKeys = captureSystemKeys
        self.swapGamepadButtons = swapGamepadButtons; self.backgroundGamepad = backgroundGamepad
        self.touchControls = touchControls; self.touchWithController = touchWithController
        self.externalDisplay = externalDisplay
        self.vsync = vsync; self.framePacing = framePacing; self.gameOptimizations = gameOptimizations
        self.quitAppAfter = quitAppAfter; self.keepAwake = keepAwake; self.performanceOverlay = performanceOverlay
        self.stopStreamOnExit = stopStreamOnExit
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let f = StreamSettings.fallback
        // `decodeIfPresent` is lenient about MISSING keys but not about unknown
        // VALUES: a present enum key whose raw value this build doesn't know
        // THROWS, and the throw escapes the whole init — so one renamed case
        // reset every setting to defaults and emptied every preset slot that
        // contained it. Decode enums via their raw value and fall back per
        // field, so an unknown value costs exactly that field.
        func enumValue<T: RawRepresentable>(_ key: CodingKeys, _ fallback: T) -> T where T.RawValue == String {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }
                .flatMap(T.init(rawValue:)) ?? fallback
        }
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? f.width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? f.height
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? f.fps
        bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps) ?? f.bitrateKbps
        codec = enumValue(.codec, f.codec)
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? f.hdr
        self.decoder = enumValue(.decoder, f.decoder)
        yuv444 = try c.decodeIfPresent(Bool.self, forKey: .yuv444) ?? f.yuv444
        audio = enumValue(.audio, f.audio)
        muteHostSpeakers = try c.decodeIfPresent(Bool.self, forKey: .muteHostSpeakers) ?? f.muteHostSpeakers
        muteOnFocusLoss = try c.decodeIfPresent(Bool.self, forKey: .muteOnFocusLoss) ?? f.muteOnFocusLoss
        absoluteMouse = try c.decodeIfPresent(Bool.self, forKey: .absoluteMouse) ?? f.absoluteMouse
        swapMouseButtons = try c.decodeIfPresent(Bool.self, forKey: .swapMouseButtons) ?? f.swapMouseButtons
        reverseScrolling = try c.decodeIfPresent(Bool.self, forKey: .reverseScrolling) ?? f.reverseScrolling
        captureSystemKeys = enumValue(.captureSystemKeys, f.captureSystemKeys)
        swapGamepadButtons = try c.decodeIfPresent(Bool.self, forKey: .swapGamepadButtons) ?? f.swapGamepadButtons
        backgroundGamepad = try c.decodeIfPresent(Bool.self, forKey: .backgroundGamepad) ?? f.backgroundGamepad
        touchControls = try c.decodeIfPresent(Bool.self, forKey: .touchControls) ?? f.touchControls
        touchWithController = try c.decodeIfPresent(Bool.self, forKey: .touchWithController) ?? f.touchWithController
        externalDisplay = try c.decodeIfPresent(Bool.self, forKey: .externalDisplay) ?? f.externalDisplay
        vsync = try c.decodeIfPresent(Bool.self, forKey: .vsync) ?? f.vsync
        framePacing = try c.decodeIfPresent(Bool.self, forKey: .framePacing) ?? f.framePacing
        gameOptimizations = try c.decodeIfPresent(Bool.self, forKey: .gameOptimizations) ?? f.gameOptimizations
        quitAppAfter = try c.decodeIfPresent(Bool.self, forKey: .quitAppAfter) ?? f.quitAppAfter
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? f.keepAwake
        performanceOverlay = try c.decodeIfPresent(Bool.self, forKey: .performanceOverlay) ?? f.performanceOverlay
        stopStreamOnExit = try c.decodeIfPresent(Bool.self, forKey: .stopStreamOnExit) ?? f.stopStreamOnExit
        self = clampedToLegalRanges()
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// A named, user-saved snapshot of stream settings — selectable from the home
/// screen so the user can flip between e.g. "4K 60" and "1080p 120" per session.
struct StreamPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var settings: StreamSettings

    /// A short "1080p · 120 fps" summary for the preset chips (home row + settings strip).
    var summary: String {
        let res: String
        switch (settings.width, settings.height) {
        case (1280, 720): res = "720p"
        case (1920, 1080): res = "1080p"
        case (2560, 1440), (3440, 1440): res = "1440p"
        case (3840, 2160): res = "4K"
        default: res = "\(settings.height)p"
        }
        return "\(res) · \(settings.fps) fps · \(settings.bitrateKbps / 1000) Mbps"
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
