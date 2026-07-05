import Foundation

/// Imports hosts, apps, pairing identity, and stream defaults from the
/// moonlight-qt preferences plist so VibeLight works instantly with zero setup.
///
/// Source of truth: ~/Library/Preferences/com.moonlight-stream.Moonlight.plist
/// (QSettings flat key format: "hosts.N.field", "hosts.N.apps.M.field").
struct MoonlightConfigImporter {
    struct ImportResult: Sendable {
        var hosts: [StreamHost]
        var identity: ClientIdentity?
        var settings: StreamSettings
    }

    enum ImportError: Error, LocalizedError {
        case plistNotFound(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .plistNotFound(let p): "Moonlight preferences not found at \(p). Is Moonlight installed and paired?"
            case .unreadable(let p): "Could not read Moonlight preferences at \(p)."
            }
        }
    }

    #if os(macOS)
    var plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.moonlight-stream.Moonlight.plist")
    #else
    // iOS is sandboxed and has no desktop-Moonlight plist to import. Point at a
    // path that never exists so importAll() cleanly reports "not found" and the
    // app falls through to its own generated identity + user-added hosts.
    var plistURL: URL = URL(fileURLWithPath: "/dev/null/com.moonlight-stream.Moonlight.plist")
    #endif

    func importAll() throws -> ImportResult {
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw ImportError.plistNotFound(plistURL.path)
        }
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.unreadable(plistURL.path)
        }

        return ImportResult(
            hosts: parseHosts(dict),
            identity: parseIdentity(dict),
            settings: parseSettings(dict)
        )
    }

    // MARK: - Hosts & apps

    private func parseHosts(_ dict: [String: Any]) -> [StreamHost] {
        let count = intValue(dict["hosts.size"]) ?? inferredCount(in: dict, prefix: "hosts.", field: "uuid")
        guard count > 0 else { return [] }
        var hosts: [StreamHost] = []
        for i in 1...count {
            let p = "hosts.\(i)."
            guard let uuid = dict[p + "uuid"] as? String, !uuid.isEmpty else { continue }
            let mac = dict[p + "mac"] as? Data
            let srvcert = dict[p + "srvcert"] as? Data
            let host = StreamHost(
                id: uuid,
                name: (dict[p + "hostname"] as? String) ?? "Unknown Host",
                localAddress: nonEmpty(dict[p + "localaddress"]),
                localPort: intValue(dict[p + "localport"]) ?? 47989,
                remoteAddress: nonEmpty(dict[p + "remoteaddress"]),
                remotePort: intValue(dict[p + "remoteport"]) ?? 47989,
                manualAddress: nonEmpty(dict[p + "manualaddress"]),
                manualPort: intValue(dict[p + "manualport"]) ?? 47989,
                macAddress: (mac?.isEmpty == false) ? mac : nil,
                serverCertPEM: (srvcert?.isEmpty == false) ? srvcert : nil,
                apps: parseApps(dict, hostPrefix: p)
            )
            hosts.append(host)
        }
        return hosts
    }

    private func parseApps(_ dict: [String: Any], hostPrefix: String) -> [StreamApp] {
        let count = intValue(dict[hostPrefix + "apps.size"])
            ?? inferredCount(in: dict, prefix: hostPrefix + "apps.", field: "id")
        guard count > 0 else { return [] }
        var apps: [StreamApp] = []
        for i in 1...count {
            let p = hostPrefix + "apps.\(i)."
            guard let id = intValue(dict[p + "id"]),
                  let rawName = dict[p + "name"] as? String else { continue }
            apps.append(StreamApp(
                id: id,
                rawName: rawName,
                uuid: nonEmpty(dict[p + "uuid"]),
                idx: nil,
                isHDRSupported: boolValue(dict[p + "hdr"]) ?? false,
                isHidden: boolValue(dict[p + "hidden"]) ?? false
            ))
        }
        return apps
    }

    // MARK: - Identity & settings

    private func parseIdentity(_ dict: [String: Any]) -> ClientIdentity? {
        guard let cert = dict["certificate"] as? Data, !cert.isEmpty,
              let key = dict["key"] as? Data, !key.isEmpty else { return nil }
        // moonlight-qt uses a fixed uniqueid for all modern clients.
        return ClientIdentity(certificatePEM: cert, privateKeyPEM: key, uniqueID: "0123456789ABCDEF")
    }

    private func parseSettings(_ dict: [String: Any]) -> StreamSettings {
        var s = StreamSettings.fallback
        if let v = intValue(dict["width"]) { s.width = v }
        if let v = intValue(dict["height"]) { s.height = v }
        if let v = intValue(dict["fps"]) { s.fps = v }
        if let v = intValue(dict["bitrate"]) { s.bitrateKbps = v }
        if let v = boolValue(dict["hdr"]) { s.hdr = v }
        if let v = boolValue(dict["vsync"]) { s.vsync = v }
        if let v = boolValue(dict["framepacing"]) { s.framePacing = v }
        // Moonlight stores height but width may be absent (derived); assume 16:9.
        if intValue(dict["width"]) == nil, let h = intValue(dict["height"]) {
            s.width = h * 16 / 9
        }
        return s
    }

    // MARK: - Plist value coercion (QSettings stores mixed types)

    private func intValue(_ v: Any?) -> Int? {
        switch v {
        case let n as Int: n
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    private func boolValue(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: b
        case let n as NSNumber: n.boolValue
        case let s as String: (s as NSString).boolValue
        default: nil
        }
    }

    private func nonEmpty(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    /// QSettings sometimes omits the ".size" key; infer count by scanning indices.
    private func inferredCount(in dict: [String: Any], prefix: String, field: String) -> Int {
        var i = 0
        while dict["\(prefix)\(i + 1).\(field)"] != nil { i += 1 }
        return i
    }
}
