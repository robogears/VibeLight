import Foundation

/// A TV as VibeLight remembers it (TV Presets, Settings ▸ Video). iOS gives
/// apps no serial number for an external display, so a TV is known by what
/// it tells iOS about itself: its resolution, its top refresh rate and the
/// list of modes it supports (from its EDID — stable for a TV, and usually
/// different between models). Two TVs of the same model share a preset.
/// The HDMI output's name, when iOS reports one, only labels the chip: it
/// can arrive a moment after the TV, so it can't be part of the key.
struct TVIdentity: Equatable, Sendable {
    /// Stable across plug-ins: what the TV preset is stored under.
    let key: String
    /// What the preset chip calls it ("LG TV", or "4K TV · 120 Hz").
    let name: String
    let width: Int
    let height: Int
    let maxFPS: Int

    init(hdmiName: String?, width: Int, height: Int, maxFPS: Int, modes: [(width: Int, height: Int)]) {
        let trimmed = hdmiName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // iOS names an adapter with no EDID name just "HDMI": that says nothing.
        let named = trimmed.isEmpty || trimmed.caseInsensitiveCompare("HDMI") == .orderedSame ? nil : trimmed
        self.width = width
        self.height = height
        self.maxFPS = maxFPS
        let modeList = Set(modes.map { "\($0.width)x\($0.height)" }).sorted().joined(separator: ",")
        key = "\(width)x\(height)@\(maxFPS)|\(modeList)"
        let label = StreamPreset.resolutionLabel(width: width, height: height)
        name = named ?? (maxFPS > 60 ? "\(label) TV · \(maxFPS) Hz" : "\(label) TV")
    }
}

/// One TV's own preset: the stream settings used whenever that TV is plugged
/// in, and changed in place by Settings while it is (owner: "change the
/// presets to just one which will be for that TV specifically").
struct TVPreset: Codable, Equatable, Sendable {
    var key: String
    var name: String
    var settings: StreamSettings

    /// The preset a TV starts with (owner): the TV's native resolution, its
    /// refresh rate as the frame rate, and 50 Mbps. Everything else is taken
    /// from `base` (the settings in use before the TV).
    static func starting(for tv: TVIdentity, from base: StreamSettings) -> TVPreset {
        var settings = base
        settings.width = tv.width / 2 * 2      // encoders want even sizes
        settings.height = tv.height / 2 * 2
        settings.fps = startingFPS(maxFPS: tv.maxFPS)
        settings.bitrateKbps = startingBitrateKbps
        return TVPreset(key: tv.key, name: tv.name, settings: settings.clampedToLegalRanges())
    }

    static let startingBitrateKbps = 50_000

    /// The TV's refresh rate as a frame rate; 60 when iOS doesn't say.
    static func startingFPS(maxFPS: Int) -> Int {
        maxFPS > 0 ? maxFPS : 60
    }
}
