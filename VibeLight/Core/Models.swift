import Foundation

/// A streaming host the person added and paired in VibeLight.
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

/// VibeLight's own client-side pairing identity (IdentityStore), presented
/// for mTLS against the host API and copied to the stream helper.
struct ClientIdentity: Sendable {
    let certificatePEM: Data
    let privateKeyPEM: Data
    /// VibeLight's `uniqueid` (IdentityStore.uniqueID), sent on every request;
    /// hosts track paired clients by it.
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

/// Settings ▸ Themes ▸ Theme: the launcher's whole look — colours, type,
/// shapes, focus, motion and background together (the tokens live in
/// `UI/Theme.swift`). A GLOBAL appearance preference on its own key, never
/// part of `StreamSettings`, so a stream preset can't change it. It replaced
/// the Background picker: Default always draws Parallax Deep, and a choice
/// saved by that picker reads as Default. Raw values persist in UserDefaults —
/// never rename one; the case order is the Settings cycle order.
enum AppTheme: String, Codable, CaseIterable, Sendable {
    case `default`, nightEdition, grid72, grid72Dark, kabukiCut

    static let storageKey = "vibelight.appTheme"
    /// Where the retired Background picker kept its choice.
    static let legacyBackgroundKey = "vibelight.backgroundTheme"

    var title: String {
        switch self {
        case .default:      "Default"
        case .nightEdition: "Night Edition"
        case .grid72:       "Grid 72"
        case .grid72Dark:   "Grid 72 Dark"
        case .kabukiCut:    "Kabuki Cut"
        }
    }

    /// Grid 72 and its ink inversion share every shape and type rule.
    var isGrid: Bool { self == .grid72 || self == .grid72Dark }

    /// The saved theme. Nothing saved — every install from before themes,
    /// whatever background it had picked — or a value this build doesn't know
    /// reads as Default.
    static func stored(in defaults: UserDefaults) -> AppTheme {
        defaults.string(forKey: storageKey).flatMap(AppTheme.init(rawValue:)) ?? .default
    }

    /// The theme to boot with. A background the old picker saved means
    /// nothing now (Default draws Parallax Deep), so its key is dropped; it
    /// never chooses a theme.
    static func migrated(in defaults: UserDefaults) -> AppTheme {
        defaults.removeObject(forKey: legacyBackgroundKey)
        return stored(in: defaults)
    }
}

/// Settings ▸ Themes ▸ Interface Size: multiplies the launcher's canvas scale
/// (`RootView.uiScale`), the custom-UI way to enlarge text Apple accepts in
/// place of Dynamic Type (UX-ios-scale-shrinks-text-targets). A GLOBAL
/// appearance preference like `AppTheme`, so loading a stream preset never
/// changes it. Raw values persist in UserDefaults — never rename.
enum InterfaceSize: String, Codable, CaseIterable, Sendable {
    case `default`, large

    var factor: CGFloat { self == .large ? 1.25 : 1.0 }

    var label: String {
        switch self {
        case .default: "Default"
        case .large:   "Large"
        }
    }
}

/// Full streaming configuration — mirrors the meaningful Moonlight settings so
/// the couch UI has the same control the desktop app does. Defaults are
/// VibeLight's own (nothing is read from Moonlight); everything is persisted
/// by VibeLight.
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
    var touchWithController: Bool  // iOS: keep touch live while a gamepad is connected
    /// iOS: stream to a connected TV. ALWAYS on (owner removed the Use TV /
    /// Monitor option); kept as a field because the engine and its tests still
    /// describe the no-TV path with it.
    var externalDisplay: Bool
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

    /// What a SAVED size is clamped to: wider than the custom entry's ranges,
    /// because the Resolution row also offers the display's Native size, and a
    /// portrait 5K panel's Native (2880×5120) is taller than 4320 — clamping
    /// it on the next launch stretched it to 2880×4320 and the row stopped
    /// reading "Native". 16384 is the largest texture macOS and iOS render, so
    /// no real display exceeds it, and 16384² can't overflow anything.
    /// (review of DAT-stored-size-overflow: Native clamp)
    static let storedWidthRange = widthRange.lowerBound...16384
    static let storedHeightRange = heightRange.lowerBound...16384

    /// This value with every number pulled into its legal range.
    func clampedToLegalRanges() -> StreamSettings {
        var s = self
        s.width = s.width.clamped(to: Self.storedWidthRange)
        s.height = s.height.clamped(to: Self.storedHeightRange)
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
         touchWithController: Bool = true,
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
        // Always on: a saved Off (setting or preset) from before the option was
        // removed must not leave the TV unusable with no switch to fix it.
        externalDisplay = true
        vsync = try c.decodeIfPresent(Bool.self, forKey: .vsync) ?? f.vsync
        framePacing = try c.decodeIfPresent(Bool.self, forKey: .framePacing) ?? f.framePacing
        // Game Optimizations, Quit Game on Disconnect and Quit Game on App Exit
        // were removed as options (owner); each is pinned to its old default
        // so a saved value from before — in settings or a preset — has no
        // hidden effect left behind with no switch to change it.
        gameOptimizations = f.gameOptimizations
        quitAppAfter = f.quitAppAfter
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? f.keepAwake
        performanceOverlay = try c.decodeIfPresent(Bool.self, forKey: .performanceOverlay) ?? f.performanceOverlay
        stopStreamOnExit = f.stopStreamOnExit
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

    /// A "1080p · 120 fps · 80 Mbps" summary for the Home preset chips. At
    /// 13 pt it is wider than a chip on an iPad's 1440-wide canvas and at
    /// Interface Size Large, so the chip falls back to `shortSummary`, then
    /// `resolutionLabel`, rather than end the line in "…" (polish 1A).
    var summary: String { "\(shortSummary) · \(settings.bitrateKbps / 1000) Mbps" }

    /// "1080p · 120 fps": what a chip shows when the full summary is too wide.
    var shortSummary: String { "\(resolutionLabel) · \(settings.fps) fps" }

    /// "1080p", "4K": the narrowest form, so a chip never shows a cut-off line.
    var resolutionLabel: String { Self.resolutionLabel(width: settings.width, height: settings.height) }

    static func resolutionLabel(width: Int, height: Int) -> String {
        switch (width, height) {
        case (1280, 720): "720p"
        case (1920, 1080): "1080p"
        case (2560, 1440), (3440, 1440): "1440p"
        case (3840, 2160): "4K"
        default: "\(height)p"
        }
    }

    /// The same summary for settings that aren't saved as a preset yet (the
    /// row's "+" chip).
    static func summary(of settings: StreamSettings) -> String {
        StreamPreset(id: "", name: "", settings: settings).summary
    }

    /// What changed from a preset's saved settings to the live ones, in the
    /// chip's words: "80 → 60 Mbps", "1080p → 4K", "HDR off". The quality
    /// numbers come first (they're what people tweak); anything else that
    /// differs is one "other settings" entry. Empty when nothing changed.
    static func changes(from old: StreamSettings, to new: StreamSettings) -> [String] {
        var out: [String] = []
        let oldRes = resolutionLabel(width: old.width, height: old.height)
        let newRes = resolutionLabel(width: new.width, height: new.height)
        if old.width != new.width || old.height != new.height {
            out.append(oldRes == newRes ? "\(old.width)×\(old.height) → \(new.width)×\(new.height)"
                                        : "\(oldRes) → \(newRes)")
        }
        if old.fps != new.fps { out.append("\(old.fps) → \(new.fps) fps") }
        if old.bitrateKbps != new.bitrateKbps {
            out.append("\(old.bitrateKbps / 1000) → \(new.bitrateKbps / 1000) Mbps")
        }
        if old.hdr != new.hdr { out.append(new.hdr ? "HDR on" : "HDR off") }
        var rest = new
        rest.width = old.width; rest.height = old.height
        rest.fps = old.fps; rest.bitrateKbps = old.bitrateKbps; rest.hdr = old.hdr
        if rest != old { out.append("other settings") }
        return out
    }

    /// Names to offer before any keyboard, from the settings themselves:
    /// "4K · 120", a word for what it's good for, the computer's name. Never
    /// "Preset 1". `current` (renaming) goes first; names other presets
    /// already use are skipped, so the first offer is always free to take.
    static func nameSuggestions(for settings: StreamSettings, hostName: String?,
                                current: String? = nil, taken: [String]) -> [String] {
        let numbers = "\(resolutionLabel(width: settings.width, height: settings.height)) · \(settings.fps)"
        let word: String
        if settings.bitrateKbps <= 20_000 { word = "Remote" }
        else if settings.height >= 2160 { word = "Big Screen" }
        else if settings.fps >= 120 { word = "Smooth" }
        else { word = "Balanced" }
        var candidates = [numbers, word]
        if let hostName, !hostName.isEmpty { candidates.append(hostName) }
        let takenSet = Set(taken.map { $0.lowercased() })
        var out: [String] = []
        if let current, !current.isEmpty { out.append(current) }
        for name in candidates {
            var pick = name
            var n = 2
            while takenSet.contains(pick.lowercased()) { pick = "\(name) \(n)"; n += 1 }
            if !out.contains(where: { $0.lowercased() == pick.lowercased() }) { out.append(pick) }
        }
        return Array(out.prefix(3))
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
